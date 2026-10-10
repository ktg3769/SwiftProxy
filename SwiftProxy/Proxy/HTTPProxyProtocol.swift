import Foundation

/// HTTP/1.x 요청 헤더 파서와 프록시용 응답 생성기.
enum HTTPProxy {
    static let maxHeadSize = 32 * 1024

    struct RequestHead: Equatable {
        var method: String
        var target: String
        var version: String
        var headers: [(name: String, value: String)]

        static func == (lhs: RequestHead, rhs: RequestHead) -> Bool {
            lhs.method == rhs.method && lhs.target == rhs.target && lhs.version == rhs.version
                && lhs.headers.map { "\($0.name):\($0.value)" } == rhs.headers.map { "\($0.name):\($0.value)" }
        }

        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    enum HeadError: Equatable {
        case tooLarge
        case malformed(String)
    }

    /// "\r\n\r\n"까지 읽어 요청 줄과 헤더를 파싱한다. 본문은 consumed 이후에 남는다.
    static func parseHead(_ b: [UInt8], maxSize: Int = maxHeadSize) -> ParseResult<Result<RequestHead, HeadError>> {
        guard let end = findHeaderEnd(b) else {
            return b.count > maxSize ? .done(.failure(.tooLarge), consumed: b.count) : .incomplete
        }
        guard end <= maxSize else { return .done(.failure(.tooLarge), consumed: end) }

        // 헤더는 ASCII가 원칙이지만 깨진 바이트로 실패하지 않도록 ISO-8859-1로 읽는다.
        guard let text = String(bytes: b[0..<(end - 4)], encoding: .isoLatin1) else {
            return .done(.failure(.malformed("헤더를 읽을 수 없습니다")), consumed: end)
        }
        var lines = text.components(separatedBy: "\r\n")
        // 요청 앞의 빈 줄은 허용 (RFC 9112 2.2)
        while lines.first == "" { lines.removeFirst() }
        guard !lines.isEmpty else { return .done(.failure(.malformed("요청 줄이 없습니다")), consumed: end) }

        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3 else {
            return .done(.failure(.malformed("요청 줄 형식이 올바르지 않습니다")), consumed: end)
        }
        let method = String(requestLine[0])
        let target = String(requestLine[1])
        let version = String(requestLine[2])
        guard !method.isEmpty, method.allSatisfy({ $0.isLetter || $0 == "-" }), !target.isEmpty else {
            return .done(.failure(.malformed("메서드 또는 대상이 올바르지 않습니다")), consumed: end)
        }
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            return .done(.failure(.malformed("지원하지 않는 HTTP 버전입니다")), consumed: end)
        }

        var headers: [(name: String, value: String)] = []
        for line in lines {
            if line.isEmpty { continue }
            if line.first == " " || line.first == "\t" {
                return .done(.failure(.malformed("헤더 줄바꿈(obs-fold)은 지원하지 않습니다")), consumed: end)
            }
            guard let colon = line.firstIndex(of: ":") else {
                return .done(.failure(.malformed("헤더 형식이 올바르지 않습니다")), consumed: end)
            }
            let name = String(line[..<colon])
            guard !name.isEmpty, !name.contains(" ") else {
                return .done(.failure(.malformed("헤더 이름이 올바르지 않습니다")), consumed: end)
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        return .done(.success(RequestHead(method: method, target: target, version: version, headers: headers)),
                     consumed: end)
    }

    /// "\r\n\r\n" 다음 위치를 돌려준다.
    static func findHeaderEnd(_ b: [UInt8]) -> Int? {
        guard b.count >= 4 else { return nil }
        var i = 0
        while i + 3 < b.count {
            if b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10 { return i + 4 }
            i += 1
        }
        return nil
    }

    /// "host:port", "[v6]:port", "host" 형식의 authority 파싱.
    static func parseAuthority(_ s: String, defaultPort: UInt16?) -> (host: TargetHost, port: UInt16)? {
        var hostPart: Substring
        var portPart: Substring?
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            hostPart = s[s.index(after: s.startIndex)..<close]
            let rest = s[s.index(after: close)...]
            if rest.isEmpty {
                portPart = nil
            } else {
                guard rest.first == ":" else { return nil }
                portPart = rest.dropFirst()
            }
        } else {
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            hostPart = parts[0]
            portPart = parts.count == 2 ? parts[1] : nil
        }
        let port: UInt16
        if let portPart {
            guard let p = UInt16(portPart), p != 0 else { return nil }
            port = p
        } else {
            guard let defaultPort else { return nil }
            port = defaultPort
        }
        guard let host = TargetHost.parse(String(hostPart)) else { return nil }
        return (host, port)
    }

    /// "http://host[:port]/path?query" → (host, port, "/path?query"). http 스킴만 지원.
    static func parseAbsoluteHTTPURL(_ target: String) -> (host: TargetHost, port: UInt16, path: String)? {
        let prefix = "http://"
        guard target.count > prefix.count,
              target.lowercased().hasPrefix(prefix) else { return nil }
        let rest = target.dropFirst(prefix.count)
        let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        var authority = String(rest[..<authorityEnd])
        // userinfo는 무시한다 (프록시 요청에서 쓰이면 안 됨)
        if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
        guard let parsed = parseAuthority(authority, defaultPort: 80) else { return nil }
        var path = String(rest[authorityEnd...])
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        if path.isEmpty || path.first == "?" { path = "/" + path }
        return (parsed.host, parsed.port, path)
    }

    /// 대상 서버로 보낼 요청 헤더를 만든다.
    /// - 요청 대상을 origin-form으로 바꾸고
    /// - Proxy-* 및 hop-by-hop 헤더를 제거하고
    /// - 연결 재사용을 하지 않도록 Connection: close를 붙인다.
    static func forwardHead(_ head: RequestHead, path: String, hostHeader: String) -> Data {
        var hopByHop: Set<String> = ["connection", "keep-alive", "proxy-connection", "proxy-authorization",
                                     "proxy-authenticate", "te", "trailer", "upgrade"]
        if let connection = head.header("Connection") {
            for token in connection.split(separator: ",") {
                hopByHop.insert(token.trimmingCharacters(in: .whitespaces).lowercased())
            }
        }
        var out = "\(head.method) \(path) \(head.version)\r\n"
        var hasHost = false
        for (name, value) in head.headers {
            let lower = name.lowercased()
            if hopByHop.contains(lower) { continue }
            if lower == "host" { hasHost = true }
            out += "\(name): \(value)\r\n"
        }
        if !hasHost { out += "Host: \(hostHeader)\r\n" }
        out += "Connection: close\r\n\r\n"
        return Data(out.utf8)
    }

    /// Proxy-Authorization: Basic 헤더에서 사용자 이름/비밀번호를 꺼낸다.
    static func basicCredentials(_ head: RequestHead) -> SOCKS5.Credentials? {
        guard let value = head.header("Proxy-Authorization") else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "basic",
              let data = Data(base64Encoded: String(parts[1]).trimmingCharacters(in: .whitespaces)),
              let decoded = String(data: data, encoding: .utf8),
              let colon = decoded.firstIndex(of: ":") else { return nil }
        return SOCKS5.Credentials(username: String(decoded[..<colon]),
                                  password: String(decoded[decoded.index(after: colon)...]))
    }

    static func response(_ status: Int, _ reason: String, headers: [(String, String)] = [], body: String = "") -> Data {
        var out = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers { out += "\(name): \(value)\r\n" }
        let bodyData = Data(body.utf8)
        out += "Content-Length: \(bodyData.count)\r\n"
        out += "Connection: close\r\n\r\n"
        return Data(out.utf8) + bodyData
    }

    static let connectEstablished = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)

    static func proxyAuthRequired() -> Data {
        response(407, "Proxy Authentication Required",
                 headers: [("Proxy-Authenticate", "Basic realm=\"SwiftProxy\"")],
                 body: "Proxy authentication required\n")
    }
}

/// PAC(Proxy Auto-Config) 파일 생성.
enum PACFile {
    static let paths: Set<String> = ["/proxy.pac", "/wpad.dat"]
    static let contentType = "application/x-ns-proxy-autoconfig"

    /// host는 클라이언트가 실제로 접속해 온 iPhone의 로컬 주소.
    static func make(host: String, httpPort: Int?, socksPort: Int?) -> String {
        let h = host.contains(":") ? "[\(host)]" : host
        var directives: [String] = []
        if let httpPort { directives.append("PROXY \(h):\(httpPort)") }
        if let socksPort {
            directives.append("SOCKS5 \(h):\(socksPort)")
            directives.append("SOCKS \(h):\(socksPort)")
        }
        let value = directives.joined(separator: "; ")
        return """
        function FindProxyForURL(url, host) {
          return "\(value)";
        }

        """
    }
}

/// 타이밍 공격을 피하기 위한 상수 시간 비교.
func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    var diff = x.count ^ y.count
    let n = max(x.count, y.count)
    for i in 0..<n {
        let p = i < x.count ? x[i] : 0
        let q = i < y.count ? y[i] : 0
        diff |= Int(p ^ q)
    }
    return diff == 0
}

import Foundation
import Network

/// 바이트 버퍼 파싱 결과. consumed는 버퍼 앞에서 소비한 바이트 수.
enum ParseResult<Value> {
    case incomplete
    case done(Value, consumed: Int)
    case invalid(String)
}

/// 프록시 대상 주소.
enum TargetHost: Equatable, Sendable, CustomStringConvertible {
    case ipv4([UInt8])
    case ipv6([UInt8])
    case domain(String)

    var description: String {
        switch self {
        case .ipv4(let b):
            return b.map(String.init).joined(separator: ".")
        case .ipv6(let b):
            var groups: [String] = []
            for i in stride(from: 0, to: 16, by: 2) {
                groups.append(String(UInt16(b[i]) << 8 | UInt16(b[i + 1]), radix: 16))
            }
            return groups.joined(separator: ":")
        case .domain(let name):
            return name
        }
    }

    /// "host:port" 표기. IPv6는 대괄호로 감싼다.
    func display(port: UInt16) -> String {
        if case .ipv6 = self { return "[\(description)]:\(port)" }
        return "\(description):\(port)"
    }

    var nwHost: NWEndpoint.Host? {
        switch self {
        case .ipv4(let b):
            return IPv4Address(Data(b)).map { NWEndpoint.Host.ipv4($0) }
        case .ipv6(let b):
            return IPv6Address(Data(b)).map { NWEndpoint.Host.ipv6($0) }
        case .domain(let name):
            return NWEndpoint.Host(name)
        }
    }

    /// iPhone 자신(loopback)을 가리키는지. 기본 설정에서는 이런 대상으로의 프록시를 막는다.
    var isLoopback: Bool {
        switch self {
        case .ipv4(let b): return b.first == 127
        case .ipv6(let b): return b == [UInt8](repeating: 0, count: 15) + [1]
        case .domain(let name):
            let lower = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return lower == "localhost" || lower.hasSuffix(".localhost")
        }
    }

    /// 문자열 호스트를 분류한다 (숫자 IP면 ipv4/ipv6, 아니면 도메인).
    static func parse(_ raw: String) -> TargetHost? {
        guard !raw.isEmpty, raw.utf8.count <= 255 else { return nil }
        var v4 = in_addr()
        if inet_pton(AF_INET, raw, &v4) == 1 {
            return .ipv4(withUnsafeBytes(of: &v4) { Array($0) })
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, raw, &v6) == 1 {
            return .ipv6(withUnsafeBytes(of: &v6) { Array($0) })
        }
        // 도메인: 공백·제어 문자·경로 구분자 금지
        let forbidden = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "/\\@?#[]"))
        guard raw.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return nil }
        return .domain(raw)
    }
}

/// SOCKS5 (RFC 1928) 및 사용자 이름/비밀번호 인증 (RFC 1929) 메시지 파서.
enum SOCKS5 {
    static let version: UInt8 = 0x05

    enum Method {
        static let noAuth: UInt8 = 0x00
        static let usernamePassword: UInt8 = 0x02
        static let noAcceptable: UInt8 = 0xFF
    }

    enum Command {
        static let connect: UInt8 = 0x01
        static let bind: UInt8 = 0x02
        static let udpAssociate: UInt8 = 0x03
    }

    enum Reply: UInt8 {
        case succeeded = 0x00
        case generalFailure = 0x01
        case notAllowed = 0x02
        case networkUnreachable = 0x03
        case hostUnreachable = 0x04
        case connectionRefused = 0x05
        case ttlExpired = 0x06
        case commandNotSupported = 0x07
        case addressTypeNotSupported = 0x08
    }

    struct Greeting: Equatable {
        let methods: [UInt8]
    }

    struct Credentials: Equatable {
        let username: String
        let password: String
    }

    struct Request: Equatable {
        let command: UInt8
        let host: TargetHost
        let port: UInt16
    }

    /// 요청은 구조상 올바르지만 처리할 수 없는 경우 (reply 코드를 돌려줘야 함).
    enum RequestError: Equatable {
        case malformed(String)
        case unsupportedAddressType(UInt8)
    }

    static func parseGreeting(_ b: [UInt8]) -> ParseResult<Greeting> {
        guard b.count >= 2 else { return .incomplete }
        guard b[0] == version else { return .invalid("SOCKS 버전이 5가 아닙니다 (\(b[0]))") }
        let n = Int(b[1])
        guard n > 0 else { return .invalid("인증 방식 목록이 비어 있습니다") }
        guard b.count >= 2 + n else { return .incomplete }
        return .done(Greeting(methods: Array(b[2..<(2 + n)])), consumed: 2 + n)
    }

    static func parseCredentials(_ b: [UInt8]) -> ParseResult<Credentials> {
        guard b.count >= 2 else { return .incomplete }
        guard b[0] == 0x01 else { return .invalid("인증 하위 협상 버전이 1이 아닙니다") }
        let ulen = Int(b[1])
        guard b.count >= 2 + ulen + 1 else { return .incomplete }
        let plen = Int(b[2 + ulen])
        let total = 3 + ulen + plen
        guard b.count >= total else { return .incomplete }
        guard ulen > 0,
              let user = String(bytes: b[2..<(2 + ulen)], encoding: .utf8),
              let pass = String(bytes: b[(3 + ulen)..<total], encoding: .utf8) else {
            return .invalid("인증 정보 형식이 올바르지 않습니다")
        }
        return .done(Credentials(username: user, password: pass), consumed: total)
    }

    /// 요청 파싱. 주소 타입이 지원되지 않으면 .done이 아니라 별도 오류로 알려 reply를 보낼 수 있게 한다.
    static func parseRequest(_ b: [UInt8]) -> ParseResult<Result<Request, RequestError>> {
        guard b.count >= 4 else { return .incomplete }
        guard b[0] == version else { return .invalid("SOCKS 버전이 5가 아닙니다 (\(b[0]))") }
        guard b[2] == 0x00 else { return .done(.failure(.malformed("예약 바이트가 0이 아닙니다")), consumed: b.count) }
        let command = b[1]
        let atyp = b[3]
        let host: TargetHost
        let addressEnd: Int
        switch atyp {
        case 0x01:
            guard b.count >= 4 + 4 + 2 else { return .incomplete }
            host = .ipv4(Array(b[4..<8]))
            addressEnd = 8
        case 0x04:
            guard b.count >= 4 + 16 + 2 else { return .incomplete }
            host = .ipv6(Array(b[4..<20]))
            addressEnd = 20
        case 0x03:
            guard b.count >= 5 else { return .incomplete }
            let len = Int(b[4])
            guard b.count >= 5 + len + 2 else { return .incomplete }
            // 도메인 자리에 숫자 IP 문자열이 와도 TargetHost.parse가 ipv4/ipv6로 분류한다.
            guard len > 0, let name = String(bytes: b[5..<(5 + len)], encoding: .utf8),
                  let parsed = TargetHost.parse(name) else {
                return .done(.failure(.malformed("도메인 이름이 올바르지 않습니다")), consumed: 7 + len)
            }
            host = parsed
            addressEnd = 5 + len
        default:
            return .done(.failure(.unsupportedAddressType(atyp)), consumed: b.count)
        }
        let port = UInt16(b[addressEnd]) << 8 | UInt16(b[addressEnd + 1])
        guard port != 0 else {
            return .done(.failure(.malformed("포트 0은 사용할 수 없습니다")), consumed: addressEnd + 2)
        }
        return .done(.success(Request(command: command, host: host, port: port)), consumed: addressEnd + 2)
    }

    static func methodSelection(_ method: UInt8) -> Data { Data([version, method]) }

    static func authResult(success: Bool) -> Data { Data([0x01, success ? 0x00 : 0x01]) }

    /// BND.ADDR/BND.PORT는 0.0.0.0:0으로 보낸다 (CONNECT 클라이언트는 이 값을 쓰지 않는다).
    static func reply(_ code: Reply) -> Data {
        Data([version, code.rawValue, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    }
}

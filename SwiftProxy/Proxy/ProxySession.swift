import Foundation
import Network

/// 클라이언트 연결 하나를 처리한다: SOCKS5 또는 HTTP 핸드셰이크 → 대상 연결 → 양방향 중계.
/// 클라이언트 쪽은 BSD 소켓(SocketTransport), 대상 쪽은 NWConnection(NWTransport)이다.
/// 모든 상태는 ProxyServerManager.queue 위에서만 바뀐다.
final class ProxySession: ProxyConnectionHandler {
    private enum Phase: Equatable {
        case socksGreeting, socksAuth, socksRequest, httpHead
        case connecting, relaying, udpAssociated, closing, closed
    }

    private enum Direction { case up, down }

    private enum ConnectOutcome {
        case ready
        case failed(SOCKS5.Reply, httpStatus: Int, message: String)
    }

    static let handshakeTimeout: TimeInterval = 15
    static let connectTimeoutSeconds = 10
    static let idleTimeout: TimeInterval = 300
    static let chunkSize = 64 * 1024

    let id: UUID
    private let kind: ListenerKind
    private let client: SocketTransport
    private weak var manager: ProxyServerManager?
    private let config: ProxyServerManager.Configuration
    private var remote: NWConnection?
    private var remoteStream: NWTransport?
    private var buffer: [UInt8] = []
    private var phase: Phase
    private var info: ConnectionInfo
    private var infoDirty = false
    private var deadline: TimeInterval
    private var lastActivity: TimeInterval
    private var upFinished = false
    private var downFinished = false
    private var udp: UDPAssociation?

    init(kind: ListenerKind, client: SocketTransport, id: UUID, manager: ProxyServerManager,
         configuration: ProxyServerManager.Configuration, clientLabel: String) {
        self.id = id
        self.kind = kind
        self.client = client
        self.manager = manager
        self.config = configuration
        self.phase = kind == .socks5 ? .socksGreeting : .httpHead
        let now = ProcessInfo.processInfo.systemUptime
        self.deadline = now + Self.handshakeTimeout
        self.lastActivity = now
        self.info = ConnectionInfo(id: id, kind: .pending, clientLabel: clientLabel, target: nil,
                                   startedAt: Date(), bytesUp: 0, bytesDown: 0)
    }

    // MARK: - ProxyConnectionHandler

    func start() {
        if rejectIfArrivedOverCellular() { return }
        receiveHandshake()
    }

    func cancel() {
        close()
    }

    func tick(now: TimeInterval) -> ConnectionInfo? {
        switch phase {
        case .socksGreeting, .socksAuth, .socksRequest, .httpHead, .connecting:
            if now > deadline {
                manager?.log(.info, "\(kind.title) 연결 시간 초과 (\(phase == .connecting ? "대상 연결" : "핸드셰이크"))")
                close()
                return nil
            }
        case .relaying:
            if now - lastActivity > Self.idleTimeout {
                manager?.log(.info, "유휴 연결 종료: \(info.target ?? "?")")
                close()
                return nil
            }
        case .udpAssociated:
            if let udp {
                udp.tick(now: now)
                if now - udp.lastActivity > Self.idleTimeout {
                    manager?.log(.info, "유휴 UDP 연결 종료")
                    close()
                    return nil
                }
                let label = "UDP · 대상 \(udp.destinationCount)개"
                if info.target != label {
                    info.target = label
                    infoDirty = true
                }
            }
        case .closing, .closed:
            return nil
        }
        guard infoDirty else { return nil }
        infoDirty = false
        return info
    }

    /// 셀룰러 인터페이스(pdp_ip*)의 주소로 들어온 연결은 외부 인터넷에서 온 것이므로 닫는다.
    private func rejectIfArrivedOverCellular() -> Bool {
        guard let local = client.localAddress, let localBytes = IPParser.bytes(local) else { return false }
        let cellular = InterfaceAddresses.all().contains {
            $0.name.hasPrefix("pdp_ip") && IPParser.bytes($0.address) == localBytes
        }
        if cellular {
            manager?.log(.warning, "셀룰러 인터페이스로 들어온 연결을 거부했습니다 (\(info.clientLabel))")
            close()
        }
        return cellular
    }

    // MARK: - Handshake

    private var queueOrMain: DispatchQueue { manager?.queue ?? .main }

    private var isHandshaking: Bool {
        switch phase {
        case .socksGreeting, .socksAuth, .socksRequest, .httpHead: return true
        default: return false
        }
    }

    private func receiveHandshake() {
        client.receive(maximumLength: 16 * 1024) { [weak self] data, isComplete, error in
            guard let self, self.isHandshaking else { return }
            if let data, !data.isEmpty {
                self.buffer.append(contentsOf: data)
                self.lastActivity = ProcessInfo.processInfo.systemUptime
            }
            if error != nil {
                self.close()
                return
            }
            self.processHandshake(clientFinished: isComplete)
        }
    }

    private func waitForMore(clientFinished: Bool) {
        if clientFinished {
            close()
        } else {
            receiveHandshake()
        }
    }

    private func processHandshake(clientFinished: Bool) {
        while phase != .closed && phase != .closing {
            switch phase {
            case .socksGreeting:
                switch SOCKS5.parseGreeting(buffer) {
                case .incomplete:
                    return waitForMore(clientFinished: clientFinished)
                case .invalid(let reason):
                    manager?.log(.warning, "SOCKS5 형식 오류: \(reason)")
                    return close()
                case .done(let greeting, let consumed):
                    buffer.removeFirst(consumed)
                    if config.credentials != nil {
                        guard greeting.methods.contains(SOCKS5.Method.usernamePassword) else {
                            manager?.log(.warning, "SOCKS5 클라이언트가 사용자 이름/비밀번호 인증을 제공하지 않음")
                            return sendAndClose(SOCKS5.methodSelection(SOCKS5.Method.noAcceptable))
                        }
                        send(SOCKS5.methodSelection(SOCKS5.Method.usernamePassword))
                        phase = .socksAuth
                    } else {
                        guard greeting.methods.contains(SOCKS5.Method.noAuth) else {
                            return sendAndClose(SOCKS5.methodSelection(SOCKS5.Method.noAcceptable))
                        }
                        send(SOCKS5.methodSelection(SOCKS5.Method.noAuth))
                        phase = .socksRequest
                    }
                }

            case .socksAuth:
                switch SOCKS5.parseCredentials(buffer) {
                case .incomplete:
                    return waitForMore(clientFinished: clientFinished)
                case .invalid(let reason):
                    manager?.log(.warning, "SOCKS5 인증 형식 오류: \(reason)")
                    return close()
                case .done(let credentials, let consumed):
                    buffer.removeFirst(consumed)
                    guard credentialsMatch(credentials) else {
                        manager?.log(.warning, "SOCKS5 인증 실패 (\(info.clientLabel))")
                        return sendAndClose(SOCKS5.authResult(success: false))
                    }
                    send(SOCKS5.authResult(success: true))
                    phase = .socksRequest
                }

            case .socksRequest:
                switch SOCKS5.parseRequest(buffer) {
                case .incomplete:
                    return waitForMore(clientFinished: clientFinished)
                case .invalid(let reason):
                    manager?.log(.warning, "SOCKS5 요청 오류: \(reason)")
                    return close()
                case .done(let result, let consumed):
                    buffer.removeFirst(min(consumed, buffer.count))
                    switch result {
                    case .failure(.unsupportedAddressType(let atyp)):
                        manager?.log(.warning, "SOCKS5 지원하지 않는 주소 타입: \(atyp)")
                        return sendAndClose(SOCKS5.reply(.addressTypeNotSupported))
                    case .failure(.malformed(let reason)):
                        manager?.log(.warning, "SOCKS5 요청 오류: \(reason)")
                        return sendAndClose(SOCKS5.reply(.generalFailure))
                    case .success(let request):
                        return beginSOCKS(request)
                    }
                }

            case .httpHead:
                switch HTTPProxy.parseHead(buffer) {
                case .incomplete:
                    return waitForMore(clientFinished: clientFinished)
                case .invalid(let reason):
                    manager?.log(.warning, "HTTP 형식 오류: \(reason)")
                    return sendAndClose(HTTPProxy.response(400, "Bad Request", body: "Bad request\n"))
                case .done(let result, let consumed):
                    buffer.removeFirst(min(consumed, buffer.count))
                    switch result {
                    case .failure(.tooLarge):
                        manager?.log(.warning, "HTTP 요청 헤더가 너무 큼")
                        return sendAndClose(HTTPProxy.response(431, "Request Header Fields Too Large"))
                    case .failure(.malformed(let reason)):
                        manager?.log(.warning, "HTTP 형식 오류: \(reason)")
                        return sendAndClose(HTTPProxy.response(400, "Bad Request", body: "Bad request\n"))
                    case .success(let head):
                        return handleHTTP(head)
                    }
                }

            case .connecting, .relaying, .udpAssociated, .closing, .closed:
                return
            }
        }
    }

    private func credentialsMatch(_ given: SOCKS5.Credentials) -> Bool {
        guard let expected = config.credentials else { return true }
        let userOK = constantTimeEquals(given.username, expected.username)
        let passOK = constantTimeEquals(given.password, expected.password)
        return userOK && passOK
    }

    // MARK: - SOCKS5

    private func beginSOCKS(_ request: SOCKS5.Request) {
        if request.command == SOCKS5.Command.udpAssociate {
            return beginUDPAssociate()
        }
        guard request.command == SOCKS5.Command.connect else {
            manager?.log(.info, "SOCKS5 명령 \(request.command) 미지원 (CONNECT, UDP ASSOCIATE만 지원)")
            return sendAndClose(SOCKS5.reply(.commandNotSupported))
        }
        let target = request.host.display(port: request.port)
        setTarget(kind: .socks5, target: target)
        guard config.allowLoopbackTargets || !request.host.isLoopback else {
            manager?.log(.warning, "loopback 대상 차단: \(target)")
            return sendAndClose(SOCKS5.reply(.notAllowed))
        }
        connectRemote(request.host, request.port) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .ready:
                self.send(SOCKS5.reply(.succeeded))
                self.startRelay(upstreamPrefix: nil)
            case .failed(let reply, _, let message):
                self.manager?.log(.info, "대상 연결 실패 \(target): \(message)")
                self.sendAndClose(SOCKS5.reply(reply))
            }
        }
    }

    /// UDP ASSOCIATE: 클라이언트용 UDP 소켓을 열고 그 주소를 알려 준다.
    /// TCP 제어 연결이 열려 있는 동안만 중계하며, 제어 연결이 끊기면 함께 닫는다 (RFC 1928 7절).
    private func beginUDPAssociate() {
        guard let peer = client.remoteAddress, let peerBytes = IPParser.bytes(peer) else {
            return sendAndClose(SOCKS5.reply(.generalFailure))
        }
        // 클라이언트가 UDP를 보낼 주소: TCP 제어 연결이 들어온 iPhone 쪽 주소 (예: 172.20.10.1)
        let localBytes = client.localAddress.flatMap(IPParser.bytes)
        let bindHost: TargetHost = localBytes.map { $0.count == 4 ? .ipv4($0) : .ipv6($0) } ?? .ipv4([0, 0, 0, 0])
        let family = (localBytes?.count ?? 4) == 16 ? AF_INET6 : AF_INET

        info.kind = .socks5UDP
        info.target = "UDP"
        infoDirty = true

        let association = UDPAssociation(
            queue: queueOrMain, clientAddress: peerBytes, outboundRoute: config.outboundRoute,
            allowLoopbackTargets: config.allowLoopbackTargets,
            onTraffic: { [weak self] up, down in
                if up > 0 { self?.account(.up, up) }
                if down > 0 { self?.account(.down, down) }
            },
            onWarning: { [weak self] message in self?.manager?.log(.warning, message) })
        do {
            let port = try association.start(family: family)
            udp = association
            phase = .udpAssociated
            lastActivity = ProcessInfo.processInfo.systemUptime
            send(SOCKS5.reply(.succeeded, bind: bindHost, port: port))
            watchControlConnection()
        } catch {
            association.close()
            manager?.log(.warning, "UDP 소켓을 열지 못했습니다: \(error)")
            sendAndClose(SOCKS5.reply(.generalFailure))
        }
    }

    /// UDP 연결 동안 TCP 제어 연결로는 데이터가 오지 않는다. 끊기면(EOF/오류) UDP 중계도 닫는다.
    private func watchControlConnection() {
        client.receive(maximumLength: 1024) { [weak self] _, isComplete, error in
            guard let self, self.phase == .udpAssociated else { return }
            if isComplete || error != nil {
                self.close()
            } else {
                self.watchControlConnection()
            }
        }
    }

    // MARK: - HTTP

    private func handleHTTP(_ head: HTTPProxy.RequestHead) {
        // origin-form 요청은 프록시 요청이 아니다. PAC 파일만 제공한다.
        if head.target.hasPrefix("/") {
            let path = String(head.target.split(separator: "?", maxSplits: 1).first ?? "")
            let method = head.method.uppercased()
            if (method == "GET" || method == "HEAD") && PACFile.paths.contains(path) {
                return servePAC()
            }
            return sendAndClose(HTTPProxy.response(400, "Bad Request", body: "This is a proxy server.\n"))
        }

        if config.credentials != nil {
            guard let given = HTTPProxy.basicCredentials(head), credentialsMatch(given) else {
                manager?.log(.warning, "HTTP 프록시 인증 실패 또는 누락 (\(info.clientLabel))")
                return sendAndClose(HTTPProxy.proxyAuthRequired())
            }
        }

        if head.method.uppercased() == "CONNECT" {
            guard let authority = HTTPProxy.parseAuthority(head.target, defaultPort: nil) else {
                return sendAndClose(HTTPProxy.response(400, "Bad Request", body: "Invalid CONNECT target\n"))
            }
            let target = authority.host.display(port: authority.port)
            setTarget(kind: .httpConnect, target: target)
            guard config.allowLoopbackTargets || !authority.host.isLoopback else {
                manager?.log(.warning, "loopback 대상 차단: \(target)")
                return sendAndClose(HTTPProxy.response(403, "Forbidden"))
            }
            connectRemote(authority.host, authority.port) { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .ready:
                    self.send(HTTPProxy.connectEstablished)
                    self.startRelay(upstreamPrefix: nil)
                case .failed(_, let status, let message):
                    self.manager?.log(.info, "대상 연결 실패 \(target): \(message)")
                    self.sendAndClose(HTTPProxy.response(status, status == 504 ? "Gateway Timeout" : "Bad Gateway",
                                                         body: "\(message)\n"))
                }
            }
            return
        }

        guard let url = HTTPProxy.parseAbsoluteHTTPURL(head.target) else {
            return sendAndClose(HTTPProxy.response(400, "Bad Request",
                                                   body: "Absolute http:// URL required. Use CONNECT for https.\n"))
        }
        let target = url.host.display(port: url.port)
        setTarget(kind: .httpForward, target: target)
        guard config.allowLoopbackTargets || !url.host.isLoopback else {
            manager?.log(.warning, "loopback 대상 차단: \(target)")
            return sendAndClose(HTTPProxy.response(403, "Forbidden"))
        }
        let hostHeader: String = {
            let h = url.host.display(port: url.port)
            if url.port == 80 { return h.hasPrefix("[") ? String(h[..<h.lastIndex(of: ":")!]) : url.host.description }
            return h
        }()
        let upstreamHead = HTTPProxy.forwardHead(head, path: url.path, hostHeader: hostHeader)
        connectRemote(url.host, url.port) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .ready:
                self.startRelay(upstreamPrefix: upstreamHead)
            case .failed(_, let status, let message):
                self.manager?.log(.info, "대상 연결 실패 \(target): \(message)")
                self.sendAndClose(HTTPProxy.response(status, status == 504 ? "Gateway Timeout" : "Bad Gateway",
                                                     body: "\(message)\n"))
            }
        }
    }

    private func servePAC() {
        let localHost = client.localAddress
            ?? InterfaceAddresses.lanAddresses().first?.address
            ?? "127.0.0.1"
        let httpPort = manager?.boundPort(.http) ?? config.httpPort
        let socksPort = manager?.boundPort(.socks5) ?? config.socksPort
        let body = PACFile.make(host: localHost, httpPort: httpPort, socksPort: socksPort)
        manager?.log(.info, "PAC 파일 제공 (\(info.clientLabel))")
        sendAndClose(HTTPProxy.response(200, "OK", headers: [("Content-Type", PACFile.contentType),
                                                              ("Cache-Control", "no-cache")], body: body))
    }

    // MARK: - Outbound

    private func connectRemote(_ host: TargetHost, _ port: UInt16, completion: @escaping (ConnectOutcome) -> Void) {
        guard let nwHost = host.nwHost, let nwPort = NWEndpoint.Port(rawValue: port) else {
            completion(.failed(.addressTypeNotSupported, httpStatus: 400, message: "잘못된 대상 주소"))
            return
        }
        phase = .connecting
        deadline = ProcessInfo.processInfo.systemUptime + TimeInterval(Self.connectTimeoutSeconds) + 5

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Self.connectTimeoutSeconds
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        let parameters = NWParameters(tls: nil, tcp: tcp)
        if config.outboundRoute == .cellularOnly {
            parameters.requiredInterfaceType = .cellular
        }

        let connection = NWConnection(host: nwHost, port: nwPort, using: parameters)
        remote = connection
        remoteStream = NWTransport(connection)
        var reported = false
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !reported else { return }
                reported = true
                guard self.phase == .connecting else { return }
                completion(.ready)
            case .waiting(let error), .failed(let error):
                guard !reported else {
                    if case .failed = state, self.phase == .relaying { self.close() }
                    return
                }
                reported = true
                guard self.phase == .connecting else { return }
                connection?.stateUpdateHandler = nil
                connection?.cancel()
                completion(Self.outcome(for: error, route: self.config.outboundRoute))
            case .cancelled:
                if self.phase == .relaying { self.close() }
            default:
                break
            }
        }
        connection.start(queue: queueOrMain)
    }

    private static func outcome(for error: NWError, route: OutboundRoute) -> ConnectOutcome {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED:
                return .failed(.connectionRefused, httpStatus: 502, message: "연결 거부됨")
            case .ENETUNREACH, .ENETDOWN:
                let hint = route == .cellularOnly ? " (셀룰러 경로 없음?)" : ""
                return .failed(.networkUnreachable, httpStatus: 502, message: "네트워크에 도달할 수 없음\(hint)")
            case .EHOSTUNREACH, .EHOSTDOWN:
                return .failed(.hostUnreachable, httpStatus: 502, message: "호스트에 도달할 수 없음")
            case .ETIMEDOUT:
                return .failed(.hostUnreachable, httpStatus: 504, message: "연결 시간 초과")
            default:
                return .failed(.generalFailure, httpStatus: 502, message: "POSIX 오류 \(code.rawValue)")
            }
        case .dns:
            return .failed(.hostUnreachable, httpStatus: 502, message: "DNS 조회 실패")
        default:
            return .failed(.generalFailure, httpStatus: 502, message: "\(error)")
        }
    }

    // MARK: - Relay

    private func startRelay(upstreamPrefix: Data?) {
        guard phase == .connecting, let remoteStream else { return }
        phase = .relaying
        lastActivity = ProcessInfo.processInfo.systemUptime

        var initial = upstreamPrefix ?? Data()
        if !buffer.isEmpty {
            initial.append(contentsOf: buffer)
            buffer.removeAll()
        }
        if !initial.isEmpty {
            account(.up, initial.count)
            remoteStream.send(initial, final: false) { [weak self] error in
                if error != nil { self?.close() }
            }
        }
        pump(.up)
        pump(.down)
    }

    /// 한 방향을 중계한다. 보낸 데이터가 처리된 뒤에야 다음 데이터를 읽는다 (backpressure).
    private func pump(_ direction: Direction) {
        guard phase == .relaying, let remoteStream else { return }
        let source: ByteStream = direction == .up ? client : remoteStream
        let destination: ByteStream = direction == .up ? remoteStream : client
        source.receive(maximumLength: Self.chunkSize) { [weak self] data, isComplete, error in
            guard let self, self.phase == .relaying else { return }
            if let data, !data.isEmpty {
                self.account(direction, data.count)
                destination.send(data, final: false) { [weak self] sendError in
                    guard let self, self.phase == .relaying else { return }
                    if sendError != nil {
                        self.close()
                    } else if isComplete {
                        self.finish(direction)
                    } else {
                        self.pump(direction)
                    }
                }
                return
            }
            if isComplete {
                self.finish(direction)
            } else if error != nil {
                self.close()
            } else {
                self.pump(direction)
            }
        }
    }

    /// 한 방향이 끝나면 반대편에 FIN을 보낸다 (half-close). 양쪽이 모두 끝나면 연결을 닫는다.
    private func finish(_ direction: Direction) {
        guard let remoteStream else { return close() }
        let destination: ByteStream = direction == .up ? remoteStream : client
        destination.send(nil, final: true) { _ in }
        if direction == .up { upFinished = true } else { downFinished = true }
        if upFinished && downFinished { close() }
    }

    private func account(_ direction: Direction, _ count: Int) {
        lastActivity = ProcessInfo.processInfo.systemUptime
        switch direction {
        case .up:
            info.bytesUp &+= UInt64(count)
            manager?.counter.addUp(count)
        case .down:
            info.bytesDown &+= UInt64(count)
            manager?.counter.addDown(count)
        }
        infoDirty = true
    }

    // MARK: - Helpers

    private func setTarget(kind: ConnectionKind, target: String) {
        info.kind = kind
        info.target = target
        infoDirty = true
    }

    private func send(_ data: Data) {
        client.send(data, final: false) { [weak self] error in
            if error != nil { self?.close() }
        }
    }

    /// 마지막 응답을 보내고 FIN 후 연결을 닫는다.
    private func sendAndClose(_ data: Data) {
        guard phase != .closed else { return }
        phase = .closing
        remote?.stateUpdateHandler = nil
        remote?.cancel()
        client.send(data, final: true) { [weak self] _ in self?.close() }
    }

    private func close() {
        guard phase != .closed else { return }
        phase = .closed
        client.cancel()
        remote?.stateUpdateHandler = nil
        remote?.cancel()
        remote = nil
        remoteStream = nil
        udp?.close()
        udp = nil
        manager?.handlerDidFinish(id)
    }
}

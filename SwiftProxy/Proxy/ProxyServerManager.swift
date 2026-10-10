import Foundation
import Network

/// 개별 클라이언트 연결을 처리하는 객체. 모든 메서드는 ProxyServerManager.queue 위에서 호출된다.
protocol ProxyConnectionHandler: AnyObject {
    var id: UUID { get }
    func start()
    func cancel()
    /// 주기적으로 호출된다. 타임아웃을 검사하고, 지난 호출 이후 바뀐 연결 정보가 있으면 돌려준다.
    func tick(now: TimeInterval) -> ConnectionInfo?
}

/// 리스너와 연결의 수명을 관리한다.
/// 내부 상태는 전용 직렬 큐(queue)에서만 접근하며, UI에는 ProxyEvent로만 알린다.
///
/// 수신은 BSD 소켓(SocketListener)으로 한다. Network.framework의 NWListener는 iPhone 안에서의 자체 접속은
/// 받았지만 개인용 핫스팟에 연결된 아이패드의 연결은 받지 못한 것이 실기기에서 확인되었다.
/// 같은 기기에서 BSD 소켓을 쓰는 a-shell(Python) 서버는 연결을 받으므로 같은 방식을 쓴다.
final class ProxyServerManager: @unchecked Sendable {
    struct Configuration: Sendable {
        var socksPort: Int?
        var httpPort: Int?
        var accessPolicy: AccessPolicy
        var allowList: [IPAddressRange]
        var credentials: ProxyCredentials?
        var revealAddressesInLogs: Bool
        var outboundRoute: OutboundRoute = .system
        /// iPhone 자신(127.0.0.1, ::1, localhost)으로의 프록시 허용 여부. 앱에서는 항상 false, 테스트에서만 true.
        var allowLoopbackTargets: Bool = false
        var maxConnections: Int = 256
    }

    /// 연결 정보 갱신과 타임아웃 검사 주기. 연결마다 타이머를 두지 않고 이 타이머 하나로 처리한다.
    static let tickInterval: DispatchTimeInterval = .seconds(2)

    typealias HandlerFactory = (_ kind: ListenerKind, _ transport: SocketTransport, _ id: UUID,
                                _ manager: ProxyServerManager) -> ProxyConnectionHandler?

    let queue = DispatchQueue(label: "com.taegun.swiftproxy.server", qos: .userInitiated)
    let counter = TrafficCounter()

    private let emit: @Sendable (ProxyEvent) -> Void
    private let makeHandler: HandlerFactory
    private var config: Configuration?
    private var listeners: [ListenerKind: SocketListener] = [:]
    private var handlers: [UUID: ProxyConnectionHandler] = [:]
    private var boundPorts: [ListenerKind: Int] = [:]
    private var tickTimer: DispatchSourceTimer?

    init(makeHandler: @escaping HandlerFactory, onEvent: @escaping @Sendable (ProxyEvent) -> Void) {
        self.makeHandler = makeHandler
        self.emit = onEvent
    }

    // MARK: - Public API (스레드 안전: 모두 queue로 넘긴다)

    func start(_ configuration: Configuration) {
        queue.async { self.startOnQueue(configuration) }
    }

    func stop() {
        queue.async { self.stopOnQueue() }
    }

    func closeConnection(_ id: UUID) {
        queue.async { self.handlers[id]?.cancel() }
    }

    func closeAllConnections() {
        queue.async { Array(self.handlers.values).forEach { $0.cancel() } }
    }

    // MARK: - Handler callbacks (queue 위에서 호출)

    var configuration: Configuration? {
        dispatchPrecondition(condition: .onQueue(queue))
        return config
    }

    func handlerDidUpdate(_ info: ConnectionInfo) {
        dispatchPrecondition(condition: .onQueue(queue))
        emit(.connectionUpdated(info))
    }

    func handlerDidFinish(_ id: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        if handlers.removeValue(forKey: id) != nil {
            emit(.connectionClosed(id))
        }
    }

    func log(_ level: LogLevel, _ message: String) {
        emit(.log(level, message))
    }

    /// 리스너가 실제로 바인딩한 포트 (port 0으로 시작한 경우 시스템이 고른 값).
    func boundPort(_ kind: ListenerKind) -> Int? {
        dispatchPrecondition(condition: .onQueue(queue))
        return boundPorts[kind]
    }

    func redact(_ address: String) -> String {
        Redactor.address(address, reveal: config?.revealAddressesInLogs ?? false)
    }

    // MARK: - Private

    private func startOnQueue(_ configuration: Configuration) {
        stopOnQueue()
        config = configuration
        counter.reset()

        if let port = configuration.socksPort {
            startListener(.socks5, port: port)
        } else {
            emit(.listener(.socks5, .disabled))
        }
        if let port = configuration.httpPort {
            startListener(.http, port: port)
        } else {
            emit(.listener(.http, .disabled))
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        tickTimer = timer
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        for handler in Array(handlers.values) {
            if let info = handler.tick(now: now) {
                emit(.connectionUpdated(info))
            }
        }
    }

    private func stopOnQueue() {
        tickTimer?.cancel()
        tickTimer = nil
        boundPorts.removeAll()
        for (kind, listener) in listeners {
            listener.cancel()
            emit(.listener(kind, .stopped))
        }
        listeners.removeAll()

        // cancel()이 handlerDidFinish를 다시 부를 수 있으므로 복사본을 순회한다.
        let active = Array(handlers.values)
        handlers.removeAll()
        for handler in active {
            handler.cancel()
            emit(.connectionClosed(handler.id))
        }
        config = nil
    }

    private func startListener(_ kind: ListenerKind, port: Int) {
        // port 0은 테스트용: 시스템이 빈 포트를 고른다. 앱 설정에서는 1024 이상만 허용된다.
        guard config != nil, (0...65535).contains(port) else {
            emit(.listener(kind, .failed("잘못된 포트")))
            return
        }
        emit(.listener(kind, .starting))
        do {
            let listener = try SocketListener(port: UInt16(port), queue: queue) { [weak self] transport in
                self?.accept(transport, kind: kind)
            }
            listeners[kind] = listener
            boundPorts[kind] = Int(listener.port)
            listener.start()
            emit(.listener(kind, .ready(port: Int(listener.port))))
            emit(.log(.info, "\(kind.title) 리스너 시작: 0.0.0.0:\(listener.port)"))
        } catch {
            let message = Self.describe(error, port: port)
            emit(.listener(kind, .failed(message)))
            emit(.log(.error, "\(kind.title) 리스너 실패: \(message)"))
        }
    }

    private func accept(_ transport: SocketTransport, kind: ListenerKind) {
        guard let config else {
            transport.cancel()
            return
        }

        let remote = transport.remoteAddress
        guard let remote,
              AccessControl.isAllowed(address: remote, policy: config.accessPolicy, allowList: config.allowList) else {
            transport.cancel()
            emit(.log(.warning, "접근 거부: \(remote.map(redact) ?? "알 수 없는 주소") → \(kind.title)"))
            return
        }

        guard handlers.count < config.maxConnections else {
            transport.cancel()
            emit(.log(.warning, "동시 연결 한도(\(config.maxConnections)) 초과로 연결 거부"))
            return
        }

        let id = UUID()
        guard let handler = makeHandler(kind, transport, id, self) else {
            transport.cancel()
            emit(.log(.warning, "\(kind.title) 처리기를 만들지 못해 연결을 닫았습니다."))
            return
        }
        handlers[id] = handler
        emit(.connectionOpened(ConnectionInfo(
            id: id, kind: .pending, clientLabel: redact(remote), target: nil,
            startedAt: Date(), bytesUp: 0, bytesDown: 0)))
        handler.start()
    }

    static func hostString(_ endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address):
            let text = "\(address)"
            if let pct = text.firstIndex(of: "%") { return String(text[..<pct]) }
            return text
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }

    static func describe(_ error: Error, port: Int) -> String {
        if let nwError = error as? NWError {
            switch nwError {
            case .posix(let code):
                switch code {
                case .EADDRINUSE: return "포트 \(port)이(가) 이미 사용 중입니다"
                case .EACCES, .EPERM: return "포트 \(port)에 바인딩할 권한이 없습니다"
                case .EADDRNOTAVAIL: return "바인딩할 주소를 사용할 수 없습니다"
                case .ENETDOWN, .ENETUNREACH: return "네트워크를 사용할 수 없습니다"
                default: return "POSIX 오류 \(code.rawValue)"
                }
            case .dns(let code): return "DNS 오류 \(code)"
            case .tls(let status): return "TLS 오류 \(status)"
            @unknown default: return "\(nwError)"
            }
        }
        return error.localizedDescription
    }
}

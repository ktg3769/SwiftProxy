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

    typealias HandlerFactory = (_ kind: ListenerKind, _ connection: NWConnection, _ id: UUID,
                                _ manager: ProxyServerManager) -> ProxyConnectionHandler?

    let queue = DispatchQueue(label: "com.taegun.swiftproxy.server", qos: .userInitiated)
    let counter = TrafficCounter()

    private let emit: @Sendable (ProxyEvent) -> Void
    private let makeHandler: HandlerFactory
    private var config: Configuration?
    private var listeners: [ListenerKind: NWListener] = [:]
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
        queue.async { self.handlers.values.forEach { $0.cancel() } }
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
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
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
        let nwPort: NWEndpoint.Port? = port == 0 ? .any : NWEndpoint.Port(rawValue: UInt16(clamping: port))
        guard let config, let nwPort, (0...65535).contains(port) else {
            emit(.listener(kind, .failed("잘못된 포트")))
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // 셀룰러 인터페이스로 들어오는 연결은 받지 않는다 (외부 인터넷에서의 접근 차단).
        parameters.prohibitedInterfaceTypes = [.cellular]
        // 접근 제어는 accept 시점의 앱 수준 검사(AccessControl)로만 한다.
        // NWParameters.acceptLocalOnly는 loopback 연결까지 거부하는 것이 CI에서 확인되었고,
        // 실기기에서의 정확한 판정 기준도 문서로 확인할 수 없어 사용하지 않는다.

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            emit(.listener(kind, .failed(Self.describe(error, port: port))))
            emit(.log(.error, "\(kind.title) 리스너 생성 실패: \(Self.describe(error, port: port))"))
            return
        }

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            self.listenerStateChanged(kind, listener: listener, state: state, port: port)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, kind: kind)
        }
        listeners[kind] = listener
        emit(.listener(kind, .starting))
        listener.start(queue: queue)
    }

    private func listenerStateChanged(_ kind: ListenerKind, listener: NWListener, state: NWListener.State, port: Int) {
        // 이미 교체되었거나 중지된 리스너의 늦은 콜백은 무시한다.
        guard listeners[kind] === listener else { return }
        switch state {
        case .setup:
            break
        case .ready:
            let actual = Int(listener.port?.rawValue ?? UInt16(clamping: port))
            boundPorts[kind] = actual
            emit(.listener(kind, .ready(port: actual)))
            emit(.log(.info, "\(kind.title) 리스너 시작: 포트 \(actual)"))
        case .waiting(let error):
            emit(.listener(kind, .waiting(Self.describe(error, port: port))))
            emit(.log(.warning, "\(kind.title) 리스너 대기: \(Self.describe(error, port: port))"))
        case .failed(let error):
            let message = Self.describe(error, port: port)
            emit(.listener(kind, .failed(message)))
            emit(.log(.error, "\(kind.title) 리스너 실패: \(message)"))
            listener.cancel()
            listeners[kind] = nil
        case .cancelled:
            listeners[kind] = nil
            emit(.listener(kind, .stopped))
        @unknown default:
            break
        }
    }

    private func accept(_ connection: NWConnection, kind: ListenerKind) {
        guard let config else {
            connection.cancel()
            return
        }

        let remote = Self.hostString(connection.endpoint)
        guard let remote,
              AccessControl.isAllowed(address: remote, policy: config.accessPolicy, allowList: config.allowList) else {
            connection.cancel()
            emit(.log(.warning, "접근 거부: \(remote.map(redact) ?? "알 수 없는 주소") → \(kind.title)"))
            return
        }

        guard handlers.count < config.maxConnections else {
            connection.cancel()
            emit(.log(.warning, "동시 연결 한도(\(config.maxConnections)) 초과로 연결 거부"))
            return
        }

        let id = UUID()
        guard let handler = makeHandler(kind, connection, id, self) else {
            connection.cancel()
            emit(.log(.warning, "\(kind.title) 처리기가 아직 구현되지 않아 연결을 닫았습니다."))
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

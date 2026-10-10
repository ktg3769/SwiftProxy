import Foundation
import Network

/// SOCKS5 UDP ASSOCIATE 하나를 처리한다.
///
/// 클라이언트(예: 아이패드의 Shadowrocket)는 "SOCKS5 헤더 + 페이로드" 데이터그램을 이 객체의 UDP 포트로 보낸다.
/// 헤더의 목적지로 페이로드를 보내고, 목적지의 응답에는 같은 형식의 헤더를 붙여 클라이언트에게 돌려준다.
/// - TCP 제어 연결의 상대 IP에서 온 데이터그램만 받는다.
/// - 조각(FRAG != 0)은 지원하지 않고 버린다.
/// - 목적지별 UDP 흐름은 일정 시간 쓰이지 않으면 닫는다.
/// 모든 메서드는 프록시 서버 큐에서 호출된다.
final class UDPAssociation {
    static let maxDestinations = 256
    static let destinationIdleTimeout: TimeInterval = 120

    private final class Destination {
        let connection: NWConnection
        let replyHeader: Data
        var lastActivity: TimeInterval

        init(connection: NWConnection, replyHeader: Data, now: TimeInterval) {
            self.connection = connection
            self.replyHeader = replyHeader
            self.lastActivity = now
        }
    }

    private let queue: DispatchQueue
    private let clientAddress: [UInt8]
    private let outboundRoute: OutboundRoute
    private let allowLoopbackTargets: Bool
    private let onTraffic: (_ up: Int, _ down: Int) -> Void
    private let onWarning: (String) -> Void

    private var listener: NWListener?
    private var clientFlow: NWConnection?
    private var destinations: [String: Destination] = [:]
    private var closed = false
    private var warnedLocalNetwork = false
    private(set) var lastActivity: TimeInterval = ProcessInfo.processInfo.systemUptime

    var destinationCount: Int { destinations.count }

    init(queue: DispatchQueue, clientAddress: [UInt8], outboundRoute: OutboundRoute, allowLoopbackTargets: Bool,
         onTraffic: @escaping (_ up: Int, _ down: Int) -> Void, onWarning: @escaping (String) -> Void) {
        self.queue = queue
        self.clientAddress = clientAddress
        self.outboundRoute = outboundRoute
        self.allowLoopbackTargets = allowLoopbackTargets
        self.onTraffic = onTraffic
        self.onWarning = onWarning
    }

    /// 클라이언트용 UDP 포트를 연다. 완료되면 바인딩된 포트를 돌려준다.
    func start(completion: @escaping (Result<UInt16, Error>) -> Void) {
        let listener: NWListener
        do {
            listener = try NWListener(using: .udp, on: .any)
        } catch {
            completion(.failure(error))
            return
        }
        self.listener = listener
        var reported = false
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !reported else { return }
                reported = true
                completion(.success(listener?.port?.rawValue ?? 0))
            case .failed(let error):
                if !reported {
                    reported = true
                    completion(.failure(error))
                }
                self.close()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] flow in
            self?.accept(flow)
        }
        listener.start(queue: queue)
    }

    func tick(now: TimeInterval) {
        for (key, destination) in destinations where now - destination.lastActivity > Self.destinationIdleTimeout {
            destination.connection.cancel()
            destinations[key] = nil
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        clientFlow?.cancel()
        clientFlow = nil
        for destination in destinations.values {
            destination.connection.stateUpdateHandler = nil
            destination.connection.cancel()
        }
        destinations.removeAll()
    }

    // MARK: - Client side

    private func accept(_ flow: NWConnection) {
        guard !closed,
              let remote = ProxyServerManager.hostString(flow.endpoint),
              IPParser.bytes(remote) == clientAddress else {
            flow.cancel()
            return
        }
        // 클라이언트가 출발 포트를 바꾼 경우 새 흐름으로 교체한다.
        if let existing = clientFlow, existing !== flow {
            existing.cancel()
        }
        clientFlow = flow
        flow.stateUpdateHandler = { [weak self, weak flow] state in
            if case .waiting = state, let flow { self?.checkLocalNetworkDenied(flow) }
        }
        flow.start(queue: queue)
        receiveFromClient(flow)
    }

    private func receiveFromClient(_ flow: NWConnection) {
        flow.receiveMessage { [weak self, weak flow] data, _, _, error in
            guard let self, let flow, !self.closed else { return }
            if let data, !data.isEmpty {
                self.handleClientDatagram(data)
            }
            if error == nil {
                self.receiveFromClient(flow)
            }
        }
    }

    private func handleClientDatagram(_ data: Data) {
        let bytes = [UInt8](data)
        guard let header = SOCKS5.parseUDPHeader(bytes), header.fragment == 0 else { return }
        if !allowLoopbackTargets && header.host.isLoopback { return }
        let payload = Data(bytes[header.length...])
        let now = ProcessInfo.processInfo.systemUptime
        lastActivity = now

        let key = header.host.display(port: header.port)
        let destination: Destination
        if let existing = destinations[key] {
            destination = existing
        } else {
            guard let created = makeDestination(key: key, host: header.host, port: header.port, now: now) else { return }
            destination = created
        }
        destination.lastActivity = now
        onTraffic(payload.count, 0)
        destination.connection.send(content: payload, completion: .contentProcessed { _ in })
    }

    // MARK: - Destination side

    private func makeDestination(key: String, host: TargetHost, port: UInt16, now: TimeInterval) -> Destination? {
        guard destinations.count < Self.maxDestinations,
              let nwHost = host.nwHost, let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let parameters = NWParameters.udp
        if outboundRoute == .cellularOnly {
            parameters.requiredInterfaceType = .cellular
        }
        let connection = NWConnection(host: nwHost, port: nwPort, using: parameters)
        let destination = Destination(connection: connection,
                                      replyHeader: SOCKS5.udpHeader(host: host, port: port), now: now)
        destinations[key] = destination
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                // 같은 키로 새로 만든 흐름을 지우지 않도록 자기 자신일 때만 제거한다.
                if let self, let connection, self.destinations[key]?.connection === connection {
                    self.destinations[key] = nil
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveFromDestination(destination)
        return destination
    }

    private func receiveFromDestination(_ destination: Destination) {
        destination.connection.receiveMessage { [weak self, weak destination] data, _, _, error in
            guard let self, let destination, !self.closed else { return }
            if let data, !data.isEmpty, let flow = self.clientFlow {
                let now = ProcessInfo.processInfo.systemUptime
                destination.lastActivity = now
                self.lastActivity = now
                self.onTraffic(0, data.count)
                flow.send(content: destination.replyHeader + data, completion: .contentProcessed { [weak self, weak flow] sendError in
                    if sendError != nil, let flow { self?.checkLocalNetworkDenied(flow) }
                })
            }
            if error == nil {
                self.receiveFromDestination(destination)
            }
        }
    }

    private func checkLocalNetworkDenied(_ flow: NWConnection) {
        guard !warnedLocalNetwork, flow.currentPath?.unsatisfiedReason == .localNetworkDenied else { return }
        warnedLocalNetwork = true
        onWarning("로컬 네트워크 권한이 없어 UDP 응답을 보낼 수 없습니다. 설정 > 개인정보 보호 및 보안 > 로컬 네트워크에서 SwiftProxy를 켜세요.")
    }
}

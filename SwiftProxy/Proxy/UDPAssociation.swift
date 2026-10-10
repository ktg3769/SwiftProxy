import Foundation
import Darwin
import Network

/// SOCKS5 UDP ASSOCIATE 하나를 처리한다.
///
/// 클라이언트(예: 아이패드의 Shadowrocket)는 "SOCKS5 헤더 + 페이로드" 데이터그램을 이 객체의 UDP 포트로 보낸다.
/// 헤더의 목적지로 페이로드를 보내고, 목적지의 응답에는 같은 형식의 헤더를 붙여 클라이언트에게 돌려준다.
/// - 클라이언트 쪽은 BSD UDP 소켓(0.0.0.0:임의 포트)으로 받는다 (TCP 리스너와 같은 이유).
/// - TCP 제어 연결의 상대 IP에서 온 데이터그램만 받는다.
/// - 조각(FRAG != 0)은 지원하지 않고 버린다.
/// - 목적지별 UDP 흐름(NWConnection)은 일정 시간 쓰이지 않으면 닫는다.
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

    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var clientSockaddr: sockaddr_storage?
    private var destinations: [String: Destination] = [:]
    private var closed = false
    private var warnedSendFailure = false
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

    deinit { close() }

    /// 클라이언트용 UDP 소켓을 연다. family는 TCP 제어 연결이 들어온 주소의 종류(AF_INET/AF_INET6).
    /// - Returns: 바인딩된 포트
    func start(family: Int32) throws -> UInt16 {
        let socketFD = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { throw SocketAddress.error(errno) }
        if SocketAddress.bindAny(socketFD, family: family, port: 0) != 0 {
            let code = errno
            Darwin.close(socketFD)
            throw SocketAddress.error(code)
        }
        SocketAddress.setNonBlocking(socketFD)
        let port = SocketAddress.local(of: socketFD).map(SocketAddress.port) ?? 0

        fd = socketFD
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.readDatagrams() }
        source.setCancelHandler { Darwin.close(socketFD) }
        source.activate()
        readSource = source
        return port
    }

    func tick(now: TimeInterval) {
        for (key, destination) in destinations where now - destination.lastActivity > Self.destinationIdleTimeout {
            destination.connection.stateUpdateHandler = nil
            destination.connection.cancel()
            destinations[key] = nil
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        readSource?.cancel()   // 취소 핸들러에서 소켓을 닫는다
        readSource = nil
        fd = -1
        for destination in destinations.values {
            destination.connection.stateUpdateHandler = nil
            destination.connection.cancel()
        }
        destinations.removeAll()
    }

    // MARK: - Client side

    private func readDatagrams() {
        guard !closed, fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !closed {
            var from = sockaddr_storage()
            var fromLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                withUnsafeMutablePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &fromLength)
                    }
                }
            }
            if count < 0 { return }   // EAGAIN: 더 읽을 데이터 없음
            guard let sender = SocketAddress.string(from), IPParser.bytes(sender) == clientAddress else { continue }
            clientSockaddr = from
            handleClientDatagram(Array(buffer[0..<count]))
        }
    }

    private func handleClientDatagram(_ bytes: [UInt8]) {
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

    private func sendToClient(_ data: Data) {
        guard !closed, fd >= 0, var address = clientSockaddr else { return }
        let length = socklen_t(address.ss_len)
        let sent = data.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, length)
                }
            }
        }
        if sent < 0 && !warnedSendFailure {
            warnedSendFailure = true
            let code = errno
            onWarning("UDP 응답을 클라이언트로 보내지 못했습니다 (errno \(code)). 설정 > 개인정보 보호 및 보안 > 로컬 네트워크에서 SwiftProxy가 켜져 있는지 확인하세요.")
        }
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
            if let data, !data.isEmpty {
                let now = ProcessInfo.processInfo.systemUptime
                destination.lastActivity = now
                self.lastActivity = now
                self.onTraffic(0, data.count)
                self.sendToClient(destination.replyHeader + data)
            }
            if error == nil {
                self.receiveFromDestination(destination)
            }
        }
    }
}

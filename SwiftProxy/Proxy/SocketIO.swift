import Foundation
import Darwin
import Network

/// 양방향 바이트 스트림. 클라이언트 쪽(BSD 소켓)과 대상 쪽(NWConnection)을 같은 방식으로 중계하기 위한 추상화.
/// 모든 메서드와 콜백은 프록시 서버 큐에서 실행된다.
protocol ByteStream: AnyObject {
    /// 데이터가 오면 (data, false, nil), 상대가 FIN을 보내면 (nil, true, nil), 오류면 (nil, false, error).
    func receive(maximumLength: Int, completion: @escaping (Data?, Bool, Error?) -> Void)
    /// final이 true면 데이터를 다 보낸 뒤 쓰기 방향을 닫는다 (half-close, FIN).
    func send(_ data: Data?, final: Bool, completion: @escaping (Error?) -> Void)
    func cancel()
}

// MARK: - 주소 도우미

enum SocketAddress {
    static func string(_ storage: sockaddr_storage) -> String? {
        var copy = storage
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(copy.ss_len)
        let rc = withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard rc == 0 else { return nil }
        var text = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        if let pct = text.firstIndex(of: "%") { text = String(text[..<pct]) }
        return text
    }

    static func port(_ storage: sockaddr_storage) -> UInt16 {
        var copy = storage
        switch Int32(copy.ss_family) {
        case AF_INET:
            return withUnsafePointer(to: &copy) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) } }
        case AF_INET6:
            return withUnsafePointer(to: &copy) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) } }
        default:
            return 0
        }
    }

    static func local(of fd: Int32) -> sockaddr_storage? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return rc == 0 ? storage : nil
    }

    static func peer(of fd: Int32) -> sockaddr_storage? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &length) }
        }
        return rc == 0 ? storage : nil
    }

    /// 와일드카드 주소(0.0.0.0 또는 ::)에 port로 bind한다.
    static func bindAny(_ fd: Int32, family: Int32, port: UInt16) -> Int32 {
        if family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_any
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: 0)
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
    }

    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    static func setOption(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32 = 1) {
        var v = value
        _ = setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size))
    }

    static func error(_ code: Int32) -> NWError {
        .posix(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    static func isRetryable(_ code: Int32) -> Bool {
        code == EAGAIN || code == EWOULDBLOCK || code == EINTR
    }
}

/// 두 디스패치 소스가 모두 취소된 뒤에 파일 디스크립터를 닫는다.
private final class DescriptorCloser {
    private let fd: Int32
    private var remaining: Int

    init(fd: Int32, users: Int) {
        self.fd = fd
        self.remaining = users
    }

    func release() {
        remaining -= 1
        if remaining == 0 { Darwin.close(fd) }
    }
}

/// 디스패치 소스의 활성/일시중지 상태를 추적한다 (일시중지된 소스를 해제하면 크래시하므로).
private final class SourceGate {
    enum State { case inactive, running, suspended }
    let source: DispatchSourceProtocol
    private(set) var state: State = .inactive
    private var cancelled = false

    init(_ source: DispatchSourceProtocol) { self.source = source }

    func run() {
        guard !cancelled else { return }
        resumeIfNeeded()
    }

    func pause() {
        guard !cancelled, state == .running else { return }
        source.suspend()
        state = .suspended
    }

    /// 취소 전에 반드시 실행 상태로 만든다 (비활성·일시중지 상태의 소스는 취소 핸들러가 돌지 않거나 해제 시 크래시).
    func cancel() {
        guard !cancelled else { return }
        resumeIfNeeded()
        cancelled = true
        source.cancel()
    }

    private func resumeIfNeeded() {
        switch state {
        case .inactive: source.activate()
        case .suspended: source.resume()
        case .running: return
        }
        state = .running
    }
}

// MARK: - TCP 리스너 (BSD 소켓)

/// a-shell의 Python 서버와 같은 방식으로 0.0.0.0(그리고 가능하면 ::)에 bind·listen 하고 accept한다.
/// Network.framework NWListener는 개인용 핫스팟 클라이언트의 연결을 전달하지 않는 사례가 실기기에서 확인되어 쓰지 않는다.
final class SocketListener {
    let port: UInt16
    private var gates: [SourceGate] = []
    private var cancelled = false

    init(port requestedPort: UInt16, queue: DispatchQueue, onAccept: @escaping (SocketTransport) -> Void) throws {
        let fd4 = try Self.makeListeningSocket(family: AF_INET, port: requestedPort)
        let actualPort = SocketAddress.local(of: fd4).map(SocketAddress.port) ?? requestedPort
        var descriptors = [fd4]
        // IPv6는 있으면 좋고 없어도 된다.
        if let fd6 = try? Self.makeListeningSocket(family: AF_INET6, port: actualPort) {
            descriptors.append(fd6)
        }
        self.port = actualPort

        for fd in descriptors {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let closer = DescriptorCloser(fd: fd, users: 1)
            source.setCancelHandler { closer.release() }
            source.setEventHandler { [weak self] in
                guard let self, !self.cancelled else { return }
                Self.acceptAll(fd: fd, queue: queue, onAccept: onAccept)
            }
            gates.append(SourceGate(source))
        }
    }

    func start() {
        gates.forEach { $0.run() }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        gates.forEach { $0.cancel() }
        gates.removeAll()
    }

    deinit { cancel() }

    private static func makeListeningSocket(family: Int32, port: UInt16) throws -> Int32 {
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw SocketAddress.error(errno) }
        SocketAddress.setOption(fd, SOL_SOCKET, SO_REUSEADDR)
        SocketAddress.setOption(fd, SOL_SOCKET, SO_NOSIGPIPE)
        if family == AF_INET6 {
            SocketAddress.setOption(fd, IPPROTO_IPV6, IPV6_V6ONLY)
        }
        if SocketAddress.bindAny(fd, family: family, port: port) != 0 {
            let code = errno
            Darwin.close(fd)
            throw SocketAddress.error(code)
        }
        if listen(fd, 128) != 0 {
            let code = errno
            Darwin.close(fd)
            throw SocketAddress.error(code)
        }
        SocketAddress.setNonBlocking(fd)
        return fd
    }

    private static func acceptAll(fd: Int32, queue: DispatchQueue, onAccept: (SocketTransport) -> Void) {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return   // EAGAIN: 대기 중인 연결 없음
            }
            SocketAddress.setNonBlocking(client)
            SocketAddress.setOption(client, SOL_SOCKET, SO_NOSIGPIPE)
            SocketAddress.setOption(client, IPPROTO_TCP, TCP_NODELAY)
            onAccept(SocketTransport(fd: client, queue: queue))
        }
    }
}

// MARK: - TCP 연결 (BSD 소켓)

final class SocketTransport: ByteStream {
    let remoteAddress: String?
    let localAddress: String?

    private let fd: Int32
    private let queue: DispatchQueue
    private let readGate: SourceGate
    private let writeGate: SourceGate
    private var pendingReceive: (maximumLength: Int, completion: (Data?, Bool, Error?) -> Void)?
    private var writes: [(data: Data, offset: Int, final: Bool, completion: (Error?) -> Void)] = []
    private var reachedEOF = false
    private var cancelled = false

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        self.remoteAddress = SocketAddress.peer(of: fd).flatMap(SocketAddress.string)
        self.localAddress = SocketAddress.local(of: fd).flatMap(SocketAddress.string)

        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        let closer = DescriptorCloser(fd: fd, users: 2)
        readSource.setCancelHandler { closer.release() }
        writeSource.setCancelHandler { closer.release() }
        readGate = SourceGate(readSource)
        writeGate = SourceGate(writeSource)
        readSource.setEventHandler { [weak self] in self?.readable() }
        writeSource.setEventHandler { [weak self] in self?.flushWrites() }
    }

    deinit { cancel() }

    func receive(maximumLength: Int, completion: @escaping (Data?, Bool, Error?) -> Void) {
        guard !cancelled else { return }
        if reachedEOF {
            queue.async { completion(nil, true, nil) }
            return
        }
        pendingReceive = (maximumLength, completion)
        readGate.run()
    }

    func send(_ data: Data?, final: Bool, completion: @escaping (Error?) -> Void) {
        guard !cancelled else {
            queue.async { completion(SocketAddress.error(ECANCELED)) }
            return
        }
        writes.append((data ?? Data(), 0, final, completion))
        flushWrites()
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        pendingReceive = nil
        writes.removeAll()
        readGate.cancel()
        writeGate.cancel()
    }

    private func readable() {
        guard !cancelled, let pending = pendingReceive else {
            readGate.pause()
            return
        }
        var buffer = Data(count: pending.maximumLength)
        let count = buffer.withUnsafeMutableBytes { raw in
            Darwin.read(fd, raw.baseAddress, pending.maximumLength)
        }
        if count > 0 {
            pendingReceive = nil
            readGate.pause()
            buffer.count = count
            pending.completion(buffer, false, nil)
        } else if count == 0 {
            reachedEOF = true
            pendingReceive = nil
            readGate.pause()
            pending.completion(nil, true, nil)
        } else {
            let code = errno
            if SocketAddress.isRetryable(code) { return }
            pendingReceive = nil
            readGate.pause()
            pending.completion(nil, false, SocketAddress.error(code))
        }
    }

    private func flushWrites() {
        guard !cancelled else {
            writeGate.pause()
            return
        }
        while !writes.isEmpty {
            var item = writes[0]
            while item.offset < item.data.count {
                let written = item.data.withUnsafeBytes { raw in
                    Darwin.write(fd, raw.baseAddress! + item.offset, item.data.count - item.offset)
                }
                if written < 0 {
                    let code = errno
                    if SocketAddress.isRetryable(code) {
                        writes[0] = item
                        writeGate.run()
                        return
                    }
                    let failed = writes
                    writes.removeAll()
                    writeGate.pause()
                    for entry in failed {
                        let completion = entry.completion
                        queue.async { completion(SocketAddress.error(code)) }
                    }
                    return
                }
                item.offset += written
            }
            writes.removeFirst()
            if item.final {
                _ = shutdown(fd, SHUT_WR)
            }
            let completion = item.completion
            queue.async { completion(nil) }
        }
        writeGate.pause()
    }
}

// MARK: - NWConnection 어댑터 (대상 서버 쪽)

final class NWTransport: ByteStream {
    let connection: NWConnection

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func receive(maximumLength: Int, completion: @escaping (Data?, Bool, Error?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
            completion(data, isComplete, error)
        }
    }

    func send(_ data: Data?, final: Bool, completion: @escaping (Error?) -> Void) {
        if final {
            connection.send(content: data, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { completion($0) })
        } else {
            connection.send(content: data, completion: .contentProcessed { completion($0) })
        }
    }

    func cancel() {
        connection.cancel()
    }
}

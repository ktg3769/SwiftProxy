import XCTest
import Network
@testable import SwiftProxy

// 시뮬레이터 안에서 loopback으로 실제 프록시 서버를 띄워 검증한다.
// 대상 서버도 테스트 안의 NWListener이므로 외부 네트워크가 필요 없다.

private enum TestError: Error, CustomStringConvertible {
    case timeout(String)
    case closed
    case connectFailed(String)
    case listenerFailed(String)

    var description: String {
        switch self {
        case .timeout(let what): return "timeout: \(what)"
        case .closed: return "connection closed"
        case .connectFailed(let why): return "connect failed: \(why)"
        case .listenerFailed(let why): return "listener failed: \(why)"
        }
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// 받은 데이터를 그대로 돌려주거나, 인사말을 보내고 닫는 대상 서버.
private final class TargetServer: @unchecked Sendable {
    enum Mode { case echo, greetAndClose(Data) }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.target")
    private let mode: Mode
    private var connections: [NWConnection] = []

    init(mode: Mode = .echo) throws {
        self.mode = mode
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        let resumed = LockedBox(false)
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) {
                        continuation.resume(returning: listener.port!.rawValue)
                    }
                case .failed(let error):
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) {
                        continuation.resume(throwing: TestError.listenerFailed("\(error)"))
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                switch self.mode {
                case .echo:
                    self.echo(connection)
                case .greetAndClose(let data):
                    connection.send(content: data, contentContext: .finalMessage, isComplete: true,
                                    completion: .contentProcessed { _ in })
                }
            }
            listener.start(queue: queue)
        }
    }

    private func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                connection.send(content: data, completion: .contentProcessed { _ in
                    if isComplete {
                        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                        completion: .contentProcessed { _ in })
                    } else {
                        self?.echo(connection)
                    }
                })
            } else if isComplete {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in })
            } else if error == nil {
                self?.echo(connection)
            }
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
        }
    }
}

/// 테스트용 TCP 클라이언트. 10초가 지나면 스스로 연결을 끊어 테스트가 멈추지 않게 한다.
private final class TestClient: @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "test.client")

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func connect() async throws {
        let resumed = LockedBox(false)
        queue.asyncAfter(deadline: .now() + 10) { [connection] in connection.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                let finish: (Error?) -> Void = { error in
                    guard resumed.withLock({ let was = $0; $0 = true; return !was }) else { return }
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
                switch state {
                case .ready: finish(nil)
                case .waiting(let error), .failed(let error): finish(TestError.connectFailed("\(error)"))
                case .cancelled: finish(TestError.closed)
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func send(_ bytes: [UInt8]) async throws { try await send(Data(bytes)) }

    func send(_ text: String) async throws { try await send(Data(text.utf8)) }

    /// 한 번 수신. (데이터, 상대가 FIN을 보냈는지)
    func receiveOnce(max: Int = 65536) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: (data, isComplete))
                } else if isComplete {
                    continuation.resume(returning: (Data(), true))
                } else {
                    continuation.resume(throwing: error ?? TestError.closed)
                }
            }
        }
    }

    func receive(exactly count: Int) async throws -> Data {
        var out = Data()
        while out.count < count {
            let (chunk, finished) = try await receiveOnce(max: count - out.count)
            out.append(chunk)
            if finished && out.count < count { throw TestError.closed }
        }
        return out
    }

    func receive(until marker: String) async throws -> String {
        var out = Data()
        let m = Data(marker.utf8)
        while out.range(of: m) == nil {
            let (chunk, finished) = try await receiveOnce()
            out.append(chunk)
            if finished { break }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// 상대가 연결을 끝낼 때까지 모두 읽는다.
    func receiveToEnd() async throws -> Data {
        var out = Data()
        while true {
            let (chunk, finished) = try await receiveOnce()
            out.append(chunk)
            if finished { return out }
        }
    }

    func close() { connection.cancel() }
}

/// 테스트용 프록시 서버 실행기.
private final class ProxyHarness: @unchecked Sendable {
    let events = LockedBox<[ProxyEvent]>([])
    let manager: ProxyServerManager

    init() {
        let events = self.events
        manager = ProxyServerManager(makeHandler: ProxyHandlerFactory.make, onEvent: { event in
            events.withLock { $0.append(event) }
        })
    }

    func start(socks: Int? = 0, http: Int? = 0, credentials: ProxyCredentials? = nil,
               allowLoopback: Bool = true) async throws -> (socks: UInt16, http: UInt16) {
        manager.start(.init(socksPort: socks, httpPort: http, accessPolicy: .localNetworkOnly, allowList: [],
                            credentials: credentials, revealAddressesInLogs: false,
                            allowLoopbackTargets: allowLoopback))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            var socksPort: UInt16 = 0, httpPort: UInt16 = 0
            for event in events.withLock({ $0 }) {
                switch event {
                case .listener(.socks5, .ready(let p)): socksPort = UInt16(p)
                case .listener(.http, .ready(let p)): httpPort = UInt16(p)
                case .listener(_, .failed(let reason)): throw TestError.listenerFailed(reason)
                default: break
                }
            }
            if (socks == nil || socksPort != 0) && (http == nil || httpPort != 0) {
                return (socksPort, httpPort)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TestError.timeout("proxy listeners")
    }

    func waitForListenerFailure(timeout: TimeInterval = 5) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for event in events.withLock({ $0 }) {
                if case .listener(_, .failed(let reason)) = event { return reason }
                if case .listener(_, .ready) = event { throw TestError.connectFailed("listener unexpectedly became ready") }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TestError.timeout("listener failure")
    }

    func stop() { manager.stop() }
}

final class ProxyIntegrationTests: XCTestCase {
    private var harness: ProxyHarness!
    private var target: TargetServer!

    override func setUp() async throws {
        harness = ProxyHarness()
        target = try TargetServer()
    }

    override func tearDown() async throws {
        harness?.stop()
        target?.stop()
        harness = nil
        target = nil
    }

    // SOCKS5 핸드셰이크 (인증 없음) 후 CONNECT 응답까지 진행한 클라이언트를 돌려준다.
    private func socksConnect(proxyPort: UInt16, request: [UInt8]) async throws -> (TestClient, UInt8) {
        let client = TestClient(port: proxyPort)
        try await client.connect()
        try await client.send([5, 1, 0])
        let received1 = try await client.receive(exactly: 2)
        XCTAssertEqual(received1, Data([5, 0]))
        try await client.send(request)
        let reply = try await client.receive(exactly: 10)
        XCTAssertEqual(reply[0], 5)
        return (client, reply[1])
    }

    private func ipv4Request(port: UInt16) -> [UInt8] {
        [5, 1, 0, 1, 127, 0, 0, 1, UInt8(port >> 8), UInt8(port & 0xFF)]
    }

    func testSOCKS5ConnectIPv4Echo() async throws {
        let targetPort = try await target.start()
        let ports = try await harness.start()
        let (client, code) = try await socksConnect(proxyPort: ports.socks, request: ipv4Request(port: targetPort))
        XCTAssertEqual(code, 0)
        try await client.send("hello proxy")
        let echoed = try await client.receive(exactly: 11)
        XCTAssertEqual(String(decoding: echoed, as: UTF8.self), "hello proxy")
        client.close()
    }

    func testSOCKS5ConnectDomainEcho() async throws {
        let targetPort = try await target.start()
        let ports = try await harness.start()
        let name = Array("localhost".utf8)
        let request: [UInt8] = [5, 1, 0, 3, UInt8(name.count)] + name + [UInt8(targetPort >> 8), UInt8(targetPort & 0xFF)]
        let (client, code) = try await socksConnect(proxyPort: ports.socks, request: request)
        XCTAssertEqual(code, 0)
        try await client.send("domain")
        let received2 = try await client.receive(exactly: 6)
        XCTAssertEqual(received2, Data("domain".utf8))
        client.close()
    }

    func testSOCKS5LargeTransfer() async throws {
        let targetPort = try await target.start()
        let ports = try await harness.start()
        let (client, code) = try await socksConnect(proxyPort: ports.socks, request: ipv4Request(port: targetPort))
        XCTAssertEqual(code, 0)
        let payload = Data((0..<(512 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        async let sent: Void = client.send(payload)
        let received = try await client.receive(exactly: payload.count)
        try await sent
        XCTAssertEqual(received, payload)
        // 통계에 반영되었는지
        let totals = harness.manager.counter.totals()
        XCTAssertGreaterThanOrEqual(totals.up, UInt64(payload.count))
        XCTAssertGreaterThanOrEqual(totals.down, UInt64(payload.count))
        client.close()
    }

    func testSOCKS5RefusedTarget() async throws {
        // 리스너를 열었다 닫아 확실히 비어 있는 포트를 얻는다.
        let closedPort = try await target.start()
        target.stop()
        try await Task.sleep(for: .milliseconds(100))
        let ports = try await harness.start()
        let (client, code) = try await socksConnect(proxyPort: ports.socks, request: ipv4Request(port: closedPort))
        XCTAssertNotEqual(code, 0)
        _ = try? await client.receiveToEnd()
        client.close()
    }

    func testSOCKS5LoopbackBlockedByDefault() async throws {
        let targetPort = try await target.start()
        let ports = try await harness.start(allowLoopback: false)
        let (client, code) = try await socksConnect(proxyPort: ports.socks, request: ipv4Request(port: targetPort))
        XCTAssertEqual(code, SOCKS5.Reply.notAllowed.rawValue)
        client.close()
    }

    func testSOCKS5UnsupportedCommand() async throws {
        let ports = try await harness.start()
        let (client, code) = try await socksConnect(proxyPort: ports.socks, request: [5, 2, 0, 1, 127, 0, 0, 1, 0, 80])
        XCTAssertEqual(code, SOCKS5.Reply.commandNotSupported.rawValue)
        client.close()
    }

    func testSOCKS5Authentication() async throws {
        let targetPort = try await target.start()
        let ports = try await harness.start(credentials: ProxyCredentials(username: "u", password: "secret-pass"))

        // 인증 방식을 제시하지 않으면 거부
        let noAuth = TestClient(port: ports.socks)
        try await noAuth.connect()
        try await noAuth.send([5, 1, 0])
        let received3 = try await noAuth.receive(exactly: 2)
        XCTAssertEqual(received3, Data([5, 0xFF]))
        noAuth.close()

        // 비밀번호가 틀리면 거부
        let wrong = TestClient(port: ports.socks)
        try await wrong.connect()
        try await wrong.send([5, 1, 2])
        let received4 = try await wrong.receive(exactly: 2)
        XCTAssertEqual(received4, Data([5, 2]))
        try await wrong.send([1, 1] + Array("u".utf8) + [5] + Array("wrong".utf8))
        let received5 = try await wrong.receive(exactly: 2)
        XCTAssertEqual(received5, Data([1, 1]))
        wrong.close()

        // 올바른 인증
        let ok = TestClient(port: ports.socks)
        try await ok.connect()
        try await ok.send([5, 2, 0, 2])
        let received6 = try await ok.receive(exactly: 2)
        XCTAssertEqual(received6, Data([5, 2]))
        try await ok.send([1, 1] + Array("u".utf8) + [11] + Array("secret-pass".utf8))
        let received7 = try await ok.receive(exactly: 2)
        XCTAssertEqual(received7, Data([1, 0]))
        try await ok.send(ipv4Request(port: targetPort))
        let reply = try await ok.receive(exactly: 10)
        XCTAssertEqual(reply[1], 0)
        try await ok.send("authed")
        let received8 = try await ok.receive(exactly: 6)
        XCTAssertEqual(received8, Data("authed".utf8))
        ok.close()
    }

    func testSOCKS5MalformedGreetingClosesConnection() async throws {
        let ports = try await harness.start()
        let client = TestClient(port: ports.socks)
        try await client.connect()
        try await client.send([4, 1, 0, 80, 127, 0, 0, 1, 0])
        let rest = try? await client.receiveToEnd()
        XCTAssertEqual(rest ?? Data(), Data())
        client.close()
    }

    func testHTTPConnectTunnel() async throws {
        let targetPort = try await target.start()
        let ports = try await harness.start()
        let client = TestClient(port: ports.http)
        try await client.connect()
        try await client.send("CONNECT 127.0.0.1:\(targetPort) HTTP/1.1\r\nHost: 127.0.0.1:\(targetPort)\r\n\r\n")
        let response = try await client.receive(until: "\r\n\r\n")
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), response)
        try await client.send("tunnel data")
        let received9 = try await client.receive(exactly: 11)
        XCTAssertEqual(received9, Data("tunnel data".utf8))
        client.close()
    }

    func testHTTPConnectRequiresAuth() async throws {
        let targetPort = try await target.start()
        let ports = try await harness.start(credentials: ProxyCredentials(username: "u", password: "pw123456"))

        let anonymous = TestClient(port: ports.http)
        try await anonymous.connect()
        try await anonymous.send("CONNECT 127.0.0.1:\(targetPort) HTTP/1.1\r\n\r\n")
        let denied = String(decoding: try await anonymous.receiveToEnd(), as: UTF8.self)
        XCTAssertTrue(denied.hasPrefix("HTTP/1.1 407"), denied)
        XCTAssertTrue(denied.contains("Proxy-Authenticate: Basic"))

        let token = Data("u:pw123456".utf8).base64EncodedString()
        let authed = TestClient(port: ports.http)
        try await authed.connect()
        try await authed.send("CONNECT 127.0.0.1:\(targetPort) HTTP/1.1\r\nProxy-Authorization: Basic \(token)\r\n\r\n")
        let ok = try await authed.receive(until: "\r\n\r\n")
        XCTAssertTrue(ok.hasPrefix("HTTP/1.1 200"), ok)
        authed.close()
    }

    func testHTTPForwardRewritesRequest() async throws {
        let targetPort = try await target.start()
        let ports = try await harness.start()
        let client = TestClient(port: ports.http)
        try await client.connect()
        // 대상이 에코 서버이므로 프록시가 보낸 요청이 그대로 되돌아온다.
        try await client.send("GET http://127.0.0.1:\(targetPort)/path?x=1 HTTP/1.1\r\nHost: 127.0.0.1:\(targetPort)\r\nProxy-Connection: keep-alive\r\n\r\n")
        let forwarded = try await client.receive(until: "\r\n\r\n")
        XCTAssertTrue(forwarded.hasPrefix("GET /path?x=1 HTTP/1.1\r\n"), forwarded)
        XCTAssertTrue(forwarded.contains("Connection: close\r\n"))
        XCTAssertFalse(forwarded.contains("Proxy-Connection"))
        client.close()
    }

    func testHTTPForwardBodyIsRelayed() async throws {
        let targetPort = try await target.start()
        let ports = try await harness.start()
        let client = TestClient(port: ports.http)
        try await client.connect()
        try await client.send("POST http://127.0.0.1:\(targetPort)/ HTTP/1.1\r\nContent-Length: 4\r\n\r\nbody")
        let forwarded = try await client.receive(until: "body")
        XCTAssertTrue(forwarded.hasSuffix("\r\n\r\nbody"), forwarded)
        client.close()
    }

    func testHTTPBadRequests() async throws {
        let ports = try await harness.start()
        for raw in ["garbage\r\n\r\n", "GET https://example.com/ HTTP/1.1\r\n\r\n", "GET /index.html HTTP/1.1\r\n\r\n",
                    "CONNECT nohostport HTTP/1.1\r\n\r\n"] {
            let client = TestClient(port: ports.http)
            try await client.connect()
            try await client.send(raw)
            let response = String(decoding: try await client.receiveToEnd(), as: UTF8.self)
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 400"), "\(raw) → \(response)")
            client.close()
        }
    }

    func testPACFileIsServed() async throws {
        let ports = try await harness.start()
        let client = TestClient(port: ports.http)
        try await client.connect()
        try await client.send("GET /proxy.pac HTTP/1.1\r\nHost: x\r\n\r\n")
        let response = String(decoding: try await client.receiveToEnd(), as: UTF8.self)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), response)
        XCTAssertTrue(response.contains("application/x-ns-proxy-autoconfig"))
        XCTAssertTrue(response.contains("FindProxyForURL"))
        XCTAssertTrue(response.contains(":\(ports.http)"), "PAC must contain the real HTTP port")
        XCTAssertTrue(response.contains("SOCKS5 "))
        XCTAssertTrue(response.contains(":\(ports.socks)"), "PAC must contain the real SOCKS port")
        client.close()
    }

    func testUpstreamCloseIsPropagated() async throws {
        let greeter = try TargetServer(mode: .greetAndClose(Data("bye".utf8)))
        defer { greeter.stop() }
        let targetPort = try await greeter.start()
        let ports = try await harness.start()
        let (client, code) = try await socksConnect(proxyPort: ports.socks, request: ipv4Request(port: targetPort))
        XCTAssertEqual(code, 0)
        let all = try await client.receiveToEnd()
        XCTAssertEqual(all, Data("bye".utf8), "client must receive data then FIN (half-close)")
        client.close()
    }

    func testConcurrentConnections() async throws {
        let targetPort = try await target.start()
        let ports = try await harness.start()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<12 {
                group.addTask {
                    let (client, code) = try await self.socksConnect(proxyPort: ports.socks,
                                                                     request: self.ipv4Request(port: targetPort))
                    XCTAssertEqual(code, 0)
                    let message = "client-\(i)-" + String(repeating: "x", count: i * 100)
                    try await client.send(message)
                    let echoed = try await client.receive(exactly: message.utf8.count)
                    XCTAssertEqual(String(decoding: echoed, as: UTF8.self), message)
                    client.close()
                }
            }
            try await group.waitForAll()
        }
    }

    func testPortConflictIsReported() async throws {
        let ports = try await harness.start(socks: 0, http: nil)
        let second = ProxyHarness()
        defer { second.stop() }
        second.manager.start(.init(socksPort: Int(ports.socks), httpPort: nil, accessPolicy: .localNetworkOnly,
                                   allowList: [], credentials: nil, revealAddressesInLogs: false))
        let reason = try await second.waitForListenerFailure()
        XCTAssertTrue(reason.contains("이미 사용 중"), reason)
    }

    func testStopClosesListenersAndConnections() async throws {
        let targetPort = try await target.start()
        let ports = try await harness.start()
        let (client, code) = try await socksConnect(proxyPort: ports.socks, request: ipv4Request(port: targetPort))
        XCTAssertEqual(code, 0)

        harness.stop()
        // 기존 연결은 끊겨야 한다.
        _ = try? await client.receiveToEnd()
        client.close()

        // 리스너도 닫혀야 한다.
        try await Task.sleep(for: .milliseconds(200))
        let late = TestClient(port: ports.socks)
        do {
            try await late.connect()
            XCTFail("listener must be closed after stop")
        } catch {
            // expected
        }
        late.close()

        let closedEvents = harness.events.withLock { $0 }.filter {
            if case .connectionClosed = $0 { return true } else { return false }
        }
        XCTAssertFalse(closedEvents.isEmpty)
    }
}

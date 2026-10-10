import Foundation
import Darwin
import Network

/// 로컬 네트워크 권한 관련 도우미.
///
/// Apple TN3179 기준:
/// - 들어오는 TCP 연결을 받는 것은 권한이 필요 없다.
/// - UDP 유니캐스트를 보내는 것은 권한이 필요하다 → SOCKS5 UDP 응답을 아이패드로 보내려면 권한이 있어야 한다.
/// - 앱이 백그라운드에서 권한이 "미결정"인 채로 로컬 네트워크 작업을 하면 알림 없이 거부된다.
/// 그래서 앱이 포그라운드일 때 권한 알림을 미리 띄운다. 알림을 직접 띄우는 API는 없으므로
/// TN3179가 제시한 방법(link-local IPv6 주소로 UDP 소켓을 connect)을 쓴다. 실제 트래픽은 보내지 않는다.
enum LocalNetworkAccess {
    static func triggerPermissionAlert() {
        for var address in linkLocalIPv6Targets() {
            let sock = socket(AF_INET6, SOCK_DGRAM, 0)
            guard sock >= 0 else { return }
            defer { close(sock) }
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = connect(sock, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
    }

    /// 브로드캐스트 가능한 인터페이스의 link-local IPv6 주소마다, 호스트 부분을 무작위로 바꾼 주소(포트 9)를 만든다.
    private static func linkLocalIPv6Targets() -> [sockaddr_in6] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [sockaddr_in6] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = ptr.pointee
            guard entry.ifa_flags & UInt32(bitPattern: IFF_BROADCAST) != 0,
                  let sa = entry.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET6),
                  Int(sa.pointee.sa_len) >= MemoryLayout<sockaddr_in6>.size else { continue }
            var address = UnsafeRawPointer(sa).load(as: sockaddr_in6.self)
            let b0 = address.sin6_addr.__u6_addr.__u6_addr8.0
            let b1 = address.sin6_addr.__u6_addr.__u6_addr8.1
            guard b0 == 0xFE && (b1 & 0xC0) == 0x80 else { continue }
            address.sin6_port = UInt16(9).bigEndian
            let random = (0..<8).map { _ in UInt8.random(in: 0...255) }
            withUnsafeMutableBytes(of: &address.sin6_addr) { buffer in
                for i in 0..<8 { buffer[8 + i] = random[i] }
            }
            result.append(address)
        }
        return result
    }
}

/// 진단용 자체 테스트: 앱 안에서 자기 SOCKS5 포트에 접속해 핸드셰이크 첫 단계가 되는지 확인한다.
/// iPhone 자신의 LAN 주소로 나가는 TCP 연결은 로컬 네트워크 권한이 필요하므로,
/// 권한이 없으면 "권한 없음"으로 표시한다 (이 경우에도 다른 기기에서 들어오는 TCP 연결은 영향 없음).
enum ProxySelfTest {
    struct Result: Identifiable, Sendable {
        let id = UUID()
        let address: String
        let success: Bool
        let detail: String
    }

    static func run(addresses: [String], port: Int, timeout: TimeInterval = 3) async -> [Result] {
        var results: [Result] = []
        for address in addresses {
            results.append(await probe(address: address, port: port, timeout: timeout))
        }
        return results
    }

    private static func probe(address: String, port: Int, timeout: TimeInterval) async -> Result {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            return Result(address: address, success: false, detail: "잘못된 포트")
        }
        let connection = NWConnection(host: NWEndpoint.Host(address), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "com.taegun.swiftproxy.selftest")
        let label = address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"

        return await withCheckedContinuation { continuation in
            var finished = false
            func finish(_ success: Bool, _ detail: String) {
                guard !finished else { return }
                finished = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: Result(address: label, success: success, detail: detail))
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data([5, 2, 0, 2]), completion: .contentProcessed { error in
                        if let error { return queue.async { finish(false, "전송 실패: \(error)") } }
                        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { data, _, _, error in
                            queue.async {
                                if let data, data.count == 2, data[data.startIndex] == 5 {
                                    finish(true, "SOCKS5 응답 정상")
                                } else {
                                    finish(false, "SOCKS5 응답 없음 \(error.map { "\($0)" } ?? "")")
                                }
                            }
                        }
                    })
                case .waiting(let error):
                    if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                        finish(false, "로컬 네트워크 권한 없음 (자체 테스트만 불가, 외부 기기의 TCP 접속은 영향 없음)")
                    } else {
                        finish(false, "연결 대기: \(error)")
                    }
                case .failed(let error):
                    finish(false, "연결 실패: \(error)")
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false, "시간 초과") }
        }
    }
}

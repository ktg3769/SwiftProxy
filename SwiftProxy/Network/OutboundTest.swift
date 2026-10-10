import Foundation
import Network

/// 앱이 외부(셀룰러)로 실제 연결을 만들 수 있는지 확인한다.
///
/// iOS는 앱이 셀룰러로 처음 데이터를 쓸 때 설정 > 셀룰러 목록에 앱을 추가한다(별도 권한 요청 API는 없음).
/// 앱 실행 시 이 테스트를 한 번 돌려 목록에 등록되게 하고, iOS가 셀룰러 사용을 막고 있는지
/// (NWPath.UnsatisfiedReason.cellularDenied) 진단 화면에 보여 준다.
enum OutboundTest {
    static func run() async -> [ProxySelfTest.Result] {
        var results: [ProxySelfTest.Result] = []
        results.append(await tcpProbe(host: "1.1.1.1", port: 443, cellularOnly: true, label: "셀룰러 TCP 1.1.1.1:443"))
        results.append(await tcpProbe(host: "1.1.1.1", port: 443, cellularOnly: false, label: "기본 경로 TCP 1.1.1.1:443"))
        results.append(await httpProbe())
        return results
    }

    private static func tcpProbe(host: String, port: UInt16, cellularOnly: Bool, label: String,
                                 timeout: TimeInterval = 6) async -> ProxySelfTest.Result {
        let parameters = NWParameters.tcp
        if cellularOnly { parameters.requiredInterfaceType = .cellular }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        let queue = DispatchQueue(label: "com.taegun.swiftproxy.outboundtest")

        return await withCheckedContinuation { continuation in
            var finished = false
            func finish(_ success: Bool, _ detail: String) {
                guard !finished else { return }
                finished = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: ProxySelfTest.Result(address: label, success: success, detail: detail))
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let interfaces = connection.currentPath?.availableInterfaces.map(\.name).joined(separator: ", ") ?? "?"
                    finish(true, "연결 성공 (인터페이스: \(interfaces))")
                case .waiting(let error):
                    finish(false, describe(connection.currentPath, error: error))
                case .failed(let error):
                    finish(false, describe(connection.currentPath, error: error))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(false, "시간 초과 (\(describe(connection.currentPath, error: nil)))")
            }
        }
    }

    private static func describe(_ path: NWPath?, error: NWError?) -> String {
        var parts: [String] = []
        if let path {
            switch path.unsatisfiedReason {
            case .cellularDenied:
                parts.append("iOS가 이 앱의 셀룰러 데이터 사용을 막고 있음 (설정 > 셀룰러에서 SwiftProxy 켜기)")
            case .wifiDenied:
                parts.append("iOS가 이 앱의 Wi-Fi 사용을 막고 있음")
            case .localNetworkDenied:
                parts.append("로컬 네트워크 권한 없음")
            case .notAvailable:
                parts.append("사용 가능한 경로 없음")
            case .vpnInactive:
                parts.append("VPN 비활성")
            @unknown default:
                break
            }
        }
        if let error { parts.append("\(error)") }
        return parts.isEmpty ? "원인 불명" : parts.joined(separator: " · ")
    }

    /// 일반 HTTP 요청 (URLSession, 시스템 기본 경로). 셀룰러 목록 등록에도 쓰인다.
    private static func httpProbe() async -> ProxySelfTest.Result {
        let label = "HTTP captive.apple.com"
        var request = URLRequest(url: URL(string: "http://captive.apple.com/hotspot-detect.html")!)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = true
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: data.prefix(200), as: UTF8.self)
            return ProxySelfTest.Result(address: label, success: status == 200 && body.contains("Success"),
                                        detail: "HTTP \(status)")
        } catch {
            return ProxySelfTest.Result(address: label, success: false, detail: error.localizedDescription)
        }
    }
}

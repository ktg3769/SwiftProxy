import Foundation
import ActivityKit

/// 앱(갱신하는 쪽)과 위젯 확장(그리는 쪽)이 함께 쓰는 Live Activity 데이터.
struct ProxyActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 앱이 마지막으로 확인한 실제 서버 상태. 앱이 멈추면 갱신이 끊기고 staleDate 이후 위젯이 "확인 불가"로 표시한다.
        var isRunning: Bool
        var connections: Int
        var upRate: Double
        var downRate: Double
        var totalUp: UInt64
        var totalDown: UInt64
        /// "Wi-Fi", "셀룰러" 등 짧은 경로 요약.
        var network: String
        /// 사용자에게 보여줄 짧은 오류. 없으면 nil.
        var error: String?
        /// "포그라운드", "백그라운드 작업 실행 중" 등.
        var backgroundMode: String
        var updatedAt: Date
    }

    var socksPort: Int?
    var httpPort: Int?
    var startedAt: Date

    static let deepLink = URL(string: "swiftproxy://dashboard")!
}

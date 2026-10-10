import Foundation
import os

/// 모든 연결이 공유하는 누적 바이트 카운터. 네트워크 큐에서 값을 더하고 메인 스레드에서 읽는다.
final class TrafficCounter: Sendable {
    struct Totals: Equatable, Sendable {
        var up: UInt64 = 0
        var down: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: Totals())

    func addUp(_ count: Int) {
        guard count > 0 else { return }
        state.withLock { $0.up &+= UInt64(count) }
    }

    func addDown(_ count: Int) {
        guard count > 0 else { return }
        state.withLock { $0.down &+= UInt64(count) }
    }

    func totals() -> Totals { state.withLock { $0 } }

    func reset() { state.withLock { $0 = Totals() } }
}

/// 누적값 두 개의 차이로 초당 전송률을 계산한다.
struct RateCalculator: Sendable {
    private var last: (totals: TrafficCounter.Totals, at: Date)?

    struct Rate: Equatable, Sendable {
        var up: Double
        var down: Double
        static let zero = Rate(up: 0, down: 0)
    }

    mutating func update(_ totals: TrafficCounter.Totals, at now: Date) -> Rate {
        defer { last = (totals, now) }
        guard let last else { return .zero }
        let dt = now.timeIntervalSince(last.at)
        guard dt > 0 else { return .zero }
        // 카운터가 리셋되어 값이 줄어든 경우 음수 속도를 내지 않는다.
        let up = totals.up >= last.totals.up ? Double(totals.up - last.totals.up) : 0
        let down = totals.down >= last.totals.down ? Double(totals.down - last.totals.down) : 0
        return Rate(up: up / dt, down: down / dt)
    }

    mutating func reset() { last = nil }
}

enum Formatters {
    static func bytes(_ value: UInt64) -> String {
        Int64(clamping: value).formatted(.byteCount(style: .binary))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(UInt64(max(0, bytesPerSecond))) + "/s"
    }

    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

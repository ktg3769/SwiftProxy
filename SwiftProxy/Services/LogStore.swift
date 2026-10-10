import Foundation
import Observation

struct LogEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let date: Date
    let level: LogLevel
    let message: String
}

/// 메모리에만 보관하는 최근 로그. 디스크에 쓰지 않으며 최대 개수를 넘으면 오래된 것부터 버린다.
/// 메시지에는 호출 측에서 이미 마스킹한 주소만 넣는다.
@MainActor
@Observable
final class LogStore {
    private(set) var entries: [LogEntry] = []
    var minimumLevel: LogLevel = .info

    @ObservationIgnored private let capacity: Int

    init(capacity: Int = 200) {
        self.capacity = capacity
    }

    func add(_ level: LogLevel, _ message: String) {
        guard level <= minimumLevel else { return }
        entries.append(LogEntry(date: Date(), level: level, message: message))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    var recentProblems: [LogEntry] {
        Array(entries.filter { $0.level <= .warning }.suffix(20).reversed())
    }

    func clear() { entries.removeAll() }
}

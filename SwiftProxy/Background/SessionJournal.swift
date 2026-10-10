import Foundation

/// 세션이 정상적으로 끝났는지 기록한다.
/// 앱 스위처에서 강제 종료되거나 시스템이 프로세스를 없애면 앱은 아무 통보도 받지 못하므로,
/// "실행 중" 표시가 남아 있는지로 다음 실행 때 비정상 종료를 추정한다.
struct SessionJournal {
    private let defaults: UserDefaults
    private let activeKey = "session.active"
    private let startedKey = "session.startedAt"
    private let endReasonKey = "session.lastEndReason"
    private let endDateKey = "session.lastEndDate"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func markStarted(at date: Date = Date()) {
        defaults.set(true, forKey: activeKey)
        defaults.set(date, forKey: startedKey)
    }

    func markEnded(reason: String, at date: Date = Date()) {
        defaults.set(false, forKey: activeKey)
        defaults.set(reason, forKey: endReasonKey)
        defaults.set(date, forKey: endDateKey)
    }

    /// 앱 시작 시 한 번 호출. 이전 세션이 정리되지 않았으면 설명 문구를 돌려주고 기록을 정리한다.
    mutating func consumeUncleanShutdown() -> String? {
        guard defaults.bool(forKey: activeKey) else { return nil }
        let started = defaults.object(forKey: startedKey) as? Date
        markEnded(reason: "비정상 종료")
        var message = "이전 프록시 세션이 정상적으로 종료되지 않았습니다. 앱 강제 종료, 시스템에 의한 종료, 또는 크래시로 추정됩니다."
        if let started {
            message += " (시작: \(started.formatted(date: .abbreviated, time: .shortened)))"
        }
        return message
    }

    var lastEnd: (reason: String, date: Date)? {
        guard let reason = defaults.string(forKey: endReasonKey),
              let date = defaults.object(forKey: endDateKey) as? Date else { return nil }
        return (reason, date)
    }
}

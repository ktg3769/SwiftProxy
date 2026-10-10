import Foundation
import ActivityKit

/// 앱 자체 Live Activity를 관리한다.
///
/// Live Activity는 표시 수단일 뿐 프로세스를 살려 두지 않는다. 앱이 일시 중지·종료되면 갱신이 멈추므로
/// 모든 갱신에 staleDate를 걸어 두고, 그 시각이 지나면 위젯이 "상태 확인 불가"로 바뀌게 한다.
@MainActor
final class LiveActivityManager {
    /// 갱신이 끊긴 뒤 상태를 믿을 수 없게 되는 시간.
    static let staleAfter: TimeInterval = 45
    /// 갱신 최소 간격 (배터리·발열 절약).
    static let minimumUpdateInterval: TimeInterval = 5

    private var activity: Activity<ProxyActivityAttributes>?
    private var lastState: ProxyActivityAttributes.ContentState?
    private var lastUpdate: Date = .distantPast

    var onError: ((String) -> Void)?

    var isActive: Bool { activity != nil }

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func start(attributes: ProxyActivityAttributes, state: ProxyActivityAttributes.ContentState) {
        guard activity == nil else {
            update(state, force: true)
            return
        }
        guard areActivitiesEnabled else {
            onError?("Live Activity가 설정에서 꺼져 있습니다.")
            return
        }
        do {
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
            activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            lastState = state
            lastUpdate = Date()
        } catch {
            onError?("Live Activity 시작 실패: \(error.localizedDescription)")
        }
    }

    /// force가 아니면 최소 간격과 내용 변화 여부를 확인한 뒤에만 갱신한다.
    func update(_ state: ProxyActivityAttributes.ContentState, force: Bool = false) {
        guard let activity else { return }
        let now = Date()
        if !force {
            guard now.timeIntervalSince(lastUpdate) >= Self.minimumUpdateInterval else { return }
            // updatedAt만 다르고 내용이 같아도 staleDate 연장을 위해 staleAfter의 절반마다는 갱신한다.
            if let lastState, Self.sameContent(lastState, state),
               now.timeIntervalSince(lastUpdate) < Self.staleAfter / 2 {
                return
            }
        }
        lastState = state
        lastUpdate = now
        let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(Self.staleAfter))
        Task { await activity.update(content) }
    }

    func end(finalState: ProxyActivityAttributes.ContentState?) {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        let content = finalState.map { ActivityContent(state: $0, staleDate: nil) }
        Task { await activity.end(content, dismissalPolicy: .immediate) }
    }

    /// 이전 실행에서 남은 Live Activity를 정리한다 (앱이 강제 종료되었던 경우 등).
    static func endLeftoverActivities() {
        for leftover in Activity<ProxyActivityAttributes>.activities {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private static func sameContent(_ a: ProxyActivityAttributes.ContentState,
                                    _ b: ProxyActivityAttributes.ContentState) -> Bool {
        a.isRunning == b.isRunning && a.connections == b.connections && a.network == b.network
            && a.error == b.error && a.backgroundMode == b.backgroundMode
            && Int(a.upRate / 1024) == Int(b.upRate / 1024) && Int(a.downRate / 1024) == Int(b.downRate / 1024)
    }
}

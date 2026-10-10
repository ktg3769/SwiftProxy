import Foundation
import BackgroundTasks

/// iOS 26 BGContinuedProcessingTask로 프록시 세션을 백그라운드에서 이어 간다.
///
/// 이 API는 원래 "끝이 있는" 작업(내보내기 등)을 위한 것이다. 프록시 서버는 끝이 없으므로
/// 앱 쪽에서 시간 제한을 두지 않고 heartbeat로 진행률을 계속 올린다. 그래도 다음 경우에는 시스템이 작업을 끝낸다:
/// - 사용자가 시스템 Live Activity에서 작업을 취소 → expirationHandler 호출
/// - 자원 부족으로 시스템이 만료 → expirationHandler 호출
/// - 앱 스위처에서 앱을 종료 → 통보 없이 종료 (SessionJournal이 다음 실행 때 감지)
@MainActor
final class BackgroundTaskManager {
    enum Status: Equatable {
        case inactive
        case submitted
        case running
        case failed(String)
        case expired

        var title: String {
            switch self {
            case .inactive: return "사용 안 함"
            case .submitted: return "제출됨 (시작 대기)"
            case .running: return "실행 중"
            case .failed(let reason): return "실패: \(reason)"
            case .expired: return "시스템/사용자에 의해 종료됨"
            }
        }
    }

    /// Info.plist BGTaskSchedulerPermittedIdentifiers에 "$(PRODUCT_BUNDLE_IDENTIFIER).proxy.*"로 등록되어 있다.
    /// Apple 문서상 식별자는 앱의 Bundle ID로 시작해야 하므로 실행 중인 Bundle ID에서 만든다.
    /// 등록은 식별자마다 한 번만 할 수 있으므로 시도마다 고유한 식별자를 쓴다.
    static var identifierPrefix: String {
        (Bundle.main.bundleIdentifier ?? "com.taegun.swiftproxy") + ".proxy."
    }
    static let title = "SwiftProxy"

    private(set) var status: Status = .inactive {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }

    var onStatusChange: ((Status) -> Void)?
    var onWarning: ((String) -> Void)?
    /// 시스템 또는 사용자가 작업을 끝냈을 때. 호출된 쪽은 서버를 정리해야 한다.
    var onExpiration: (() -> Void)?

    private var identifier: String?
    /// 제출 후 이 시간 안에 시작되지 않으면 실패로 본다 (Apple: .fail은 즉시 시작되거나 오류여야 함).
    static let startWatchdog: TimeInterval = 15

    /// 실행 중인 앱의 Bundle ID와 Info.plist의 허용 식별자 (재서명 도구가 Bundle ID를 바꿨는지 확인용).
    static var runtimeBundleID: String { Bundle.main.bundleIdentifier ?? "?" }
    static var permittedPatterns: [String] {
        Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
    }
    /// 허용 식별자가 현재 Bundle ID 아래에 있는지. 아니면 iOS가 작업을 받아 놓고 실행하지 않는다 (SideStore #1475).
    static var permittedPatternsMatchBundle: Bool {
        let prefix = runtimeBundleID + "."
        return permittedPatterns.contains { $0.hasPrefix(prefix) }
    }
    private var task: BGContinuedProcessingTask?
    private var heartbeatCount: Int64 = 0

    var isActive: Bool { status == .submitted || status == .running }

    /// 사용자가 시작 버튼을 눌렀을 때(앱이 포그라운드일 때)만 호출해야 한다.
    func begin(subtitle: String) {
        guard !isActive else { return }   // 중복 제출 방지
        // 실기기에서 동작이 확인된 구현들은 .queue를 명시한다. .fail은 "받아들여졌지만 시작되지 않는" 사례가 보고되어 쓰지 않는다.
        _ = submit(subtitle: subtitle, strategy: .queue)
    }

    private func submit(subtitle: String, strategy: BGContinuedProcessingTaskRequest.SubmissionStrategy) -> Bool {

        let identifier = Self.identifierPrefix + UUID().uuidString.lowercased()
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let task = task as? BGContinuedProcessingTask, self.identifier == identifier else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.attach(task)
            }
        }
        guard registered else {
            status = .failed("작업 등록 실패 (Info.plist 허용 식별자와 Bundle ID 불일치 가능: \(Bundle.main.bundleIdentifier ?? "?"))")
            return false
        }

        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: Self.title, subtitle: subtitle)
        request.strategy = strategy
        do {
            try BGTaskScheduler.shared.submit(request)
            self.identifier = identifier
            status = .submitted
            scheduleStartWatchdog(for: identifier)
            return true
        } catch {
            status = .failed(Self.describe(error))
            return false
        }
    }

    /// 진행률과 부제목을 갱신한다. 앱이 살아 있는 동안 주기적으로 호출된다.
    /// 프록시에는 "완료율"이 없으므로 heartbeat 횟수를 진행률로 보고하고, 전체 단위를 계속 늘려 끝나지 않게 한다.
    func heartbeat(subtitle: String) {
        guard let task else { return }
        heartbeatCount += 1
        let progress = task.progress
        // 완료 단위는 계속 늘리고(진행 중임을 알림), 전체는 그 두 배 이상으로 잡아 진행률이 50% 근처에 머물게 한다.
        // 진행률이 100%에 가까운데 작업이 남아 있으면 시스템이 빨리 만료시킨다는 보고가 있다.
        progress.totalUnitCount = heartbeatCount * 2 + 100
        progress.completedUnitCount = heartbeatCount
        task.updateTitle(Self.title, subtitle: subtitle)
    }

    /// 사용자가 서버를 중지했을 때. 정상 완료로 보고한다.
    func end() {
        if let task {
            task.expirationHandler = nil
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: true)
        } else if let identifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        task = nil
        identifier = nil
        heartbeatCount = 0
        status = .inactive
    }

    private func scheduleStartWatchdog(for submitted: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startWatchdog) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.status == .submitted, self.identifier == submitted else { return }
                // 요청은 취소하지 않는다 (.queue는 조금 늦게 시작될 수 있음). 원인 판단에 필요한 정보만 알린다.
                if !Self.permittedPatternsMatchBundle {
                    self.onWarning?("백그라운드 작업이 시작되지 않음: Bundle ID(\(Self.runtimeBundleID))가 허용 식별자(\(Self.permittedPatterns.joined(separator: ", ")))와 맞지 않습니다.")
                } else {
                    self.onWarning?("백그라운드 작업이 \(Int(Self.startWatchdog))초가 지나도 시작되지 않았습니다 (대기열에서 대기 중).")
                }
            }
        }
    }

    private func attach(_ task: BGContinuedProcessingTask) {
        self.task = task
        heartbeatCount = 0
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = 1
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in self?.expired() }
        }
        status = .running
    }

    private func expired() {
        guard let task else { return }
        self.task = nil
        identifier = nil
        status = .expired
        onExpiration?()
        task.setTaskCompleted(success: false)
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? BGTaskScheduler.Error {
            switch error.code {
            case .unavailable: return "이 기기/환경에서 사용할 수 없음"
            case .notPermitted: return "허용되지 않은 작업 식별자"
            case .tooManyPendingTaskRequests: return "대기 중인 작업이 너무 많음"
            @unknown default: return "BGTaskScheduler 오류 \(error.code.rawValue)"
            }
        }
        return error.localizedDescription
    }
}

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

    /// Info.plist BGTaskSchedulerPermittedIdentifiers에 "com.taegun.swiftproxy.proxy.*"로 등록되어 있다.
    /// 등록은 한 번만 할 수 있으므로 세션마다 고유한 식별자를 만든다.
    static let identifierPrefix = "com.taegun.swiftproxy.proxy."
    static let title = "SwiftProxy"

    private(set) var status: Status = .inactive {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }

    var onStatusChange: ((Status) -> Void)?
    /// 시스템 또는 사용자가 작업을 끝냈을 때. 호출된 쪽은 서버를 정리해야 한다.
    var onExpiration: (() -> Void)?

    private var identifier: String?
    private var task: BGContinuedProcessingTask?
    private var heartbeatCount: Int64 = 0

    var isActive: Bool { status == .submitted || status == .running }

    /// 사용자가 시작 버튼을 눌렀을 때(앱이 포그라운드일 때)만 호출해야 한다.
    func begin(subtitle: String) {
        guard !isActive else { return }   // 중복 제출 방지

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
            status = .failed("작업 등록 실패")
            return
        }

        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: Self.title, subtitle: subtitle)
        // 바로 시작할 수 없으면 대기열에 넣지 않고 실패시킨다 (나중에 엉뚱한 시점에 시작되는 것을 막기 위해).
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            self.identifier = identifier
            status = .submitted
        } catch {
            status = .failed(Self.describe(error))
        }
    }

    /// 진행률과 부제목을 갱신한다. 앱이 살아 있는 동안 주기적으로 호출된다.
    /// 프록시에는 "완료율"이 없으므로 heartbeat 횟수를 진행률로 보고하고, 전체 단위를 계속 늘려 끝나지 않게 한다.
    func heartbeat(subtitle: String) {
        guard let task else { return }
        heartbeatCount += 1
        let progress = task.progress
        progress.totalUnitCount = heartbeatCount + 1
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

    private func attach(_ task: BGContinuedProcessingTask) {
        self.task = task
        heartbeatCount = 0
        task.progress.totalUnitCount = 1
        task.progress.completedUnitCount = 0
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

import Foundation
import Observation
import UIKit

/// 앱 전체 상태. UI는 이 객체만 관찰한다.
@MainActor
@Observable
final class AppState {
    let settingsStore: SettingsStore
    let pathMonitor: NetworkPathMonitor
    let log: LogStore

    private(set) var socksStatus: ListenerStatus = .stopped
    private(set) var httpStatus: ListenerStatus = .stopped
    /// 사용자가 서버 실행을 요청한 상태인지 (실제 리스너 상태는 socksStatus/httpStatus).
    private(set) var runRequested = false
    private(set) var startedAt: Date?
    private(set) var totals = TrafficCounter.Totals()
    private(set) var rate = RateCalculator.Rate.zero
    private(set) var connections: [UUID: ConnectionInfo] = [:]
    private(set) var lastError: String?
    private(set) var lanAddresses: [InterfaceAddress] = []
    private(set) var backgroundStatus: BackgroundTaskManager.Status = .inactive
    /// 이번 실행에서 수락한 연결 수 (진단용: 다른 기기의 연결이 실제로 들어오는지 확인).
    private(set) var acceptedTotal = 0
    /// 이번 실행에서 받자마자 거부한 연결 수 (접근 정책 등).
    private(set) var rejectedTotal = 0
    private(set) var outboundResults: [ProxySelfTest.Result] = []
    private(set) var outboundRunning = false
    private(set) var isInBackground = false
    /// 이전 세션이 비정상 종료되었거나 시스템이 백그라운드 작업을 끝낸 경우의 안내.
    private(set) var sessionNotice: String?

    @ObservationIgnored private var server: ProxyServerManager!
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var rateCalculator = RateCalculator()
    @ObservationIgnored private var didLaunch = false
    @ObservationIgnored private let backgroundTasks = BackgroundTaskManager()
    @ObservationIgnored private let liveActivity = LiveActivityManager()
    @ObservationIgnored private let mdnsAlias = MDNSAlias()
    @ObservationIgnored private var journal = SessionJournal()
    @ObservationIgnored private var graceTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var lastHeartbeat = Date.distantPast
    @ObservationIgnored private var suspendedWithoutBackgroundTask = false

    /// BGContinuedProcessingTask 진행률·Live Activity 갱신 간격.
    static let heartbeatInterval: TimeInterval = 5

    init() {
        let settingsStore = SettingsStore()
        self.settingsStore = settingsStore
        self.pathMonitor = NetworkPathMonitor()
        self.log = LogStore()
        self.log.minimumLevel = settingsStore.settings.logLevel

        // 이벤트 순서를 보장하기 위해 Task 대신 main 큐에 순서대로 넣는다.
        self.server = ProxyServerManager(
            makeHandler: ProxyHandlerFactory.make,
            onEvent: { [weak self] event in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.handle(event) }
                }
            })

        pathMonitor.onChange = { [weak self] snapshot in
            self?.networkChanged(snapshot)
        }
        backgroundTasks.onStatusChange = { [weak self] status in
            self?.backgroundStatus = status
            self?.log.add(status == .running || status == .inactive ? .info : .warning,
                          "백그라운드 작업 상태: \(status.title)")
        }
        backgroundTasks.onWarning = { [weak self] message in
            self?.log.add(.warning, message)
        }
        backgroundTasks.onExpiration = { [weak self] in
            self?.backgroundTaskExpired()
        }
        liveActivity.onError = { [weak self] message in
            self?.log.add(.warning, message)
        }
        mdnsAlias.onError = { [weak self] message in
            self?.log.add(.warning, message)
        }
    }

    // MARK: - Derived

    var isRunning: Bool { runRequested && (socksStatus.isReady || httpStatus.isReady) }

    var activeConnectionCount: Int { connections.count }

    var sortedConnections: [ConnectionInfo] {
        connections.values.sorted { $0.startedAt > $1.startedAt }
    }

    var statusTitle: String {
        if isRunning { return "실행 중" }
        if runRequested {
            if socksStatus.isFailure || httpStatus.isFailure { return "오류" }
            return "시작 중"
        }
        return "중지됨"
    }

    var backgroundModeTitle: String {
        if !runRequested { return "중지됨" }
        if backgroundTasks.status == .running { return isInBackground ? "백그라운드 작업 실행 중" : "포그라운드 (백그라운드 작업 준비됨)" }
        if isInBackground { return "백그라운드 (백그라운드 작업 없음: iOS가 일시 중지할 수 있음)" }
        return "포그라운드"
    }

    // MARK: - Lifecycle

    func onLaunch() {
        guard !didLaunch else { return }
        didLaunch = true
        LiveActivityManager.endLeftoverActivities()
        if let notice = journal.consumeUncleanShutdown() {
            sessionNotice = notice
            log.add(.warning, notice)
        }
        pathMonitor.start()
        refreshAddresses()
        // SOCKS5 UDP 응답을 다른 기기로 보내려면 로컬 네트워크 권한이 필요하다.
        // 백그라운드에서는 알림이 뜨지 않고 거부되므로 포그라운드인 지금 미리 요청한다.
        LocalNetworkAccess.triggerPermissionAlert()
        // 셀룰러로 실제 연결을 한 번 만들어 iOS 설정 > 셀룰러 목록에 등록되게 하고, 결과를 진단에 표시한다.
        runOutboundTest()
        if settingsStore.settings.autoStart {
            log.add(.info, "자동 시작: 백그라운드 작업은 버튼을 눌러야 요청됩니다 (버튼이 아닌 제출은 iOS가 취소함).")
            start(userInitiated: false)
        }
    }

    func sceneDidEnterBackground() {
        isInBackground = true
        guard runRequested else { return }
        if backgroundTasks.status == .running {
            log.add(.info, "백그라운드 전환: BGContinuedProcessingTask로 계속 실행")
            pushHeartbeat(force: true)
            return
        }
        // 백그라운드 작업이 없으면 iOS가 유예 시간 뒤 앱을 일시 중지한다. 앱은 서버를 끄지 않는다.
        // 일시 중지되는 동안은 연결을 처리할 수 없으며, 앱으로 돌아오면 리스너를 다시 연다.
        log.add(.warning, "백그라운드 작업(\(backgroundTasks.status.title)) 없이 백그라운드로 전환됨. 서버는 끄지 않지만 iOS가 앱을 일시 중지하면 그동안 연결을 받지 못합니다.")
        suspendedWithoutBackgroundTask = true
        beginGracePeriod()
        pushHeartbeat(force: true)
    }

    func sceneDidBecomeActive() {
        if isInBackground { log.add(.info, "앱이 포그라운드로 돌아옴") }
        isInBackground = false
        endGracePeriod()
        refreshAddresses()
        guard runRequested else { return }
        // 일시 중지 중에 iOS가 소켓을 무효화했을 수 있으므로 리스너를 다시 연다 (서버는 계속 실행 상태).
        if suspendedWithoutBackgroundTask {
            suspendedWithoutBackgroundTask = false
            reopenListeners()
        }
        pushHeartbeat(force: true)
    }

    /// 대시보드의 "백그라운드 유지 다시 요청" 버튼.
    func requestBackgroundTask() {
        guard runRequested, !backgroundTasks.isActive else { return }
        backgroundTasks.begin(subtitle: portSummary(settingsStore.settings))
        if case .failed(let reason) = backgroundTasks.status {
            log.add(.warning, "백그라운드 작업 요청 실패: \(reason)")
        }
    }

    /// 서버를 끄지 않고 리스너만 다시 연다 (백그라운드 작업·Live Activity·통계 유지).
    private func reopenListeners() {
        guard let config = makeConfiguration() else { return }
        log.add(.info, "리스너 다시 열기")
        server.start(config)
    }

    private func makeConfiguration() -> ProxyServerManager.Configuration? {
        let settings = settingsStore.settings
        var credentials: ProxyCredentials?
        if settings.authEnabled {
            guard let password = settingsStore.password() else { return nil }
            credentials = ProxyCredentials(username: settings.authUsername, password: password)
        }
        return ProxyServerManager.Configuration(
            socksPort: settings.socksEnabled ? settings.socksPort : nil,
            httpPort: settings.httpEnabled ? settings.httpPort : nil,
            accessPolicy: settings.accessPolicy,
            allowList: settings.allowList.compactMap { IPAddressRange(cidr: $0) },
            credentials: credentials,
            revealAddressesInLogs: settings.logLevel == .debug,
            outboundRoute: settings.outboundRoute)
    }

    func dismissNotice() { sessionNotice = nil }

    private(set) var selfTestResults: [ProxySelfTest.Result] = []
    private(set) var selfTestRunning = false

    /// 외부 연결 테스트 (셀룰러 전용 TCP, 기본 경로 TCP, HTTP).
    func runOutboundTest() {
        guard !outboundRunning else { return }
        outboundRunning = true
        Task {
            let results = await OutboundTest.run()
            self.outboundResults = results
            self.outboundRunning = false
            for result in results where !result.success {
                self.log.add(.warning, "외부 연결 테스트 실패 [\(result.address)]: \(result.detail)")
            }
        }
    }

    /// 진단 탭의 자체 테스트: iPhone의 LAN 주소(Wi-Fi·핫스팟)로 자기 SOCKS5 포트에 접속해 본다.
    func runSelfTest() {
        guard !selfTestRunning else { return }
        let settings = settingsStore.settings
        guard runRequested, settings.socksEnabled else {
            selfTestResults = [ProxySelfTest.Result(address: "-", success: false, detail: "SOCKS5 서버가 실행 중이 아닙니다")]
            return
        }
        refreshAddresses()
        let addresses = lanAddresses.filter { !$0.isLinkLocal }.map(\.address)
        guard !addresses.isEmpty else {
            selfTestResults = [ProxySelfTest.Result(address: "-", success: false, detail: "Wi-Fi/핫스팟 주소가 없습니다. 핫스팟이 켜져 있고 기기가 연결되어 있는지 확인하세요.")]
            return
        }
        selfTestRunning = true
        Task {
            let results = await ProxySelfTest.run(addresses: addresses, port: settings.socksPort)
            self.selfTestResults = results
            self.selfTestRunning = false
        }
    }

    // MARK: - Control

    /// - Parameter userInitiated: 사용자가 버튼을 눌렀는지. BGContinuedProcessingTask는 이 경우에만 제출할 수 있다.
    func start(userInitiated: Bool = true) {
        let settings = settingsStore.settings
        let errors = SettingsValidator.validate(settings)
        guard errors.isEmpty else {
            lastError = errors.joined(separator: "\n")
            log.add(.error, "설정 오류로 시작하지 못했습니다.")
            return
        }

        var credentials: ProxyCredentials?
        if settings.authEnabled {
            guard let password = settingsStore.password() else {
                lastError = "인증이 켜져 있지만 비밀번호가 없습니다. 설정에서 비밀번호를 생성하세요."
                return
            }
            credentials = ProxyCredentials(username: settings.authUsername, password: password)
        }

        let config = ProxyServerManager.Configuration(
            socksPort: settings.socksEnabled ? settings.socksPort : nil,
            httpPort: settings.httpEnabled ? settings.httpPort : nil,
            accessPolicy: settings.accessPolicy,
            allowList: settings.allowList.compactMap { IPAddressRange(cidr: $0) },
            credentials: credentials,
            revealAddressesInLogs: settings.logLevel == .debug,
            outboundRoute: settings.outboundRoute)

        lastError = nil
        sessionNotice = nil
        runRequested = true
        let now = Date()
        startedAt = now
        connections.removeAll()
        totals = .init()
        rate = .zero
        rateCalculator.reset()
        refreshAddresses()
        server.start(config)
        startStatsLoop()
        mdnsAlias.update(MDNSAlias.currentEntries())
        journal.markStarted(at: now)
        log.add(.info, "서버 시작 요청")

        if userInitiated && settings.useContinuedProcessing {
            backgroundTasks.begin(subtitle: portSummary(settings))
            if case .failed(let reason) = backgroundTasks.status {
                log.add(.warning, "백그라운드 작업 요청 실패: \(reason). 대시보드에서 다시 요청할 수 있습니다.")
            }
        }
        if settings.showLiveActivity {
            liveActivity.start(
                attributes: ProxyActivityAttributes(
                    socksPort: settings.socksEnabled ? settings.socksPort : nil,
                    httpPort: settings.httpEnabled ? settings.httpPort : nil,
                    startedAt: now),
                state: activityState())
        }
    }

    func stop(reason: String = "사용자가 중지") {
        guard runRequested else { return }
        server.stop()
        runRequested = false
        startedAt = nil
        statsTask?.cancel()
        statsTask = nil
        connections.removeAll()
        rate = .zero
        socksStatus = .stopped
        httpStatus = .stopped
        backgroundTasks.end()
        mdnsAlias.stop()
        liveActivity.end(finalState: activityState())
        journal.markEnded(reason: reason)
        endGracePeriod()
        log.add(.info, "서버 중지: \(reason)")
    }

    /// 설정 변경 후 재시작. 설정 화면에서 저장 버튼을 누른 사용자 동작이므로 백그라운드 작업을 다시 요청한다.
    func restartIfRunning() {
        guard runRequested else { return }
        stop(reason: "설정 변경으로 재시작")
        start(userInitiated: !isInBackground)
    }

    func closeConnection(_ id: UUID) { server.closeConnection(id) }

    func closeAllConnections() { server.closeAllConnections() }

    /// 설정 화면에서 저장할 때 호출. 실행 중이면 새 설정으로 재시작한다.
    func applySettings(_ draft: ProxySettings) -> [String] {
        let errors = settingsStore.apply(draft)
        guard errors.isEmpty else { return errors }
        log.minimumLevel = draft.logLevel
        log.add(.info, "설정 저장됨")
        restartIfRunning()
        return []
    }

    func refreshAddresses() {
        lanAddresses = InterfaceAddresses.lanAddresses()
        // 실행 중이면 고정 이름(swiftproxy.local)이 현재 IPv6 주소를 가리키도록 갱신한다.
        if runRequested { mdnsAlias.update(MDNSAlias.currentEntries()) }
    }

    // MARK: - Background

    /// 시스템 또는 사용자가 백그라운드 작업을 끝냈을 때. 서버는 끄지 않는다.
    /// iOS가 이후 앱을 일시 중지하면 그동안 연결을 받지 못하고, 앱으로 돌아오면 리스너를 다시 열고 작업을 다시 요청한다.
    private func backgroundTaskExpired() {
        sessionNotice = "iOS가 백그라운드 작업을 종료했습니다 (시스템 Live Activity에서 취소했거나 자원 부족). 서버는 켜진 상태로 두었으며, 앱으로 돌아오면 작업을 다시 요청합니다."
        log.add(.warning, "백그라운드 작업 종료됨 (서버는 유지)")
        if isInBackground {
            suspendedWithoutBackgroundTask = true
            beginGracePeriod()
        }
    }

    private func beginGracePeriod() {
        guard graceTask == .invalid else { return }
        graceTask = UIApplication.shared.beginBackgroundTask(withName: "SwiftProxyGrace") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.runRequested && self.backgroundTasks.status != .running {
                    self.log.add(.warning, "백그라운드 유예 시간 종료: iOS가 앱을 일시 중지합니다 (서버 설정은 유지).")
                }
                self.endGracePeriod()
            }
        }
    }

    private func endGracePeriod() {
        guard graceTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(graceTask)
        graceTask = .invalid
    }

    private func pushHeartbeat(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastHeartbeat) >= Self.heartbeatInterval else { return }
        lastHeartbeat = now
        backgroundTasks.heartbeat(subtitle: heartbeatSubtitle())
        liveActivity.update(activityState(), force: force)
    }

    private func heartbeatSubtitle() -> String {
        var parts = ["연결 \(activeConnectionCount)"]
        parts.append("↓\(Formatters.rate(rate.down))")
        if let startedAt { parts.append(Formatters.duration(Date().timeIntervalSince(startedAt))) }
        return parts.joined(separator: " · ")
    }

    private func portSummary(_ s: ProxySettings) -> String {
        var parts: [String] = []
        if s.socksEnabled { parts.append("SOCKS5 :\(s.socksPort)") }
        if s.httpEnabled { parts.append("HTTP :\(s.httpPort)") }
        return parts.joined(separator: " · ")
    }

    private func activityState() -> ProxyActivityAttributes.ContentState {
        let failure: String? = {
            if case .failed(let r) = socksStatus { return "SOCKS5: \(r)" }
            if case .failed(let r) = httpStatus { return "HTTP: \(r)" }
            return nil
        }()
        return ProxyActivityAttributes.ContentState(
            isRunning: isRunning,
            connections: activeConnectionCount,
            upRate: rate.up,
            downRate: rate.down,
            totalUp: totals.up,
            totalDown: totals.down,
            network: pathMonitor.current.summary,
            error: failure,
            backgroundMode: backgroundModeTitle,
            updatedAt: Date())
    }

    // MARK: - Events

    private func handle(_ event: ProxyEvent) {
        switch event {
        case .listener(let kind, let status):
            // 중지 후 늦게 도착한 이벤트가 상태를 되살리지 않도록 한다.
            if !runRequested, status != .stopped, status != .disabled { return }
            switch kind {
            case .socks5: socksStatus = status
            case .http: httpStatus = status
            }
            if case .failed(let reason) = status {
                lastError = "\(kind.title): \(reason)"
            }
            if runRequested { pushHeartbeat(force: true) }
        case .connectionOpened(let info):
            guard runRequested else { return }
            acceptedTotal += 1
            connections[info.id] = info
        case .connectionUpdated(let info):
            guard runRequested, connections[info.id] != nil else { return }
            connections[info.id] = info
        case .connectionClosed(let id):
            connections.removeValue(forKey: id)
        case .connectionRejected:
            rejectedTotal += 1
        case .log(let level, let message):
            log.add(level, message)
            if level == .error { lastError = message }
        }
    }

    private func networkChanged(_ snapshot: PathSnapshot) {
        refreshAddresses()
        log.add(.info, "네트워크 변경: \(snapshot.summary)")
        if runRequested {
            if lanAddresses.isEmpty {
                log.add(.warning, "Wi-Fi/핫스팟 주소가 없어 다른 기기가 접속할 수 없습니다.")
            }
            pushHeartbeat(force: true)
        }
    }

    private func startStatsLoop() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.settingsStore.settings.statsInterval ?? 1
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                self.tickStats()
            }
        }
    }

    private func tickStats() {
        let now = Date()
        let current = server.counter.totals()
        rate = rateCalculator.update(current, at: now)
        if current != totals { totals = current }
        pushHeartbeat()
    }
}

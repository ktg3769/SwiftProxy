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

    @ObservationIgnored private var server: ProxyServerManager!
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var rateCalculator = RateCalculator()
    @ObservationIgnored private var didLaunch = false

    init() {
        let settingsStore = SettingsStore()
        self.settingsStore = settingsStore
        self.pathMonitor = NetworkPathMonitor()
        self.log = LogStore()
        self.log.minimumLevel = settingsStore.settings.logLevel

        self.server = ProxyServerManager(
            makeHandler: ProxyHandlerFactory.make,
            onEvent: { [weak self] event in
                Task { @MainActor [weak self] in self?.handle(event) }
            })

        pathMonitor.onChange = { [weak self] snapshot in
            self?.networkChanged(snapshot)
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

    // MARK: - Lifecycle

    func onLaunch() {
        guard !didLaunch else { return }
        didLaunch = true
        pathMonitor.start()
        refreshAddresses()
        if settingsStore.settings.autoStart {
            log.add(.info, "자동 시작 설정에 따라 서버를 시작합니다.")
            start()
        }
    }

    // MARK: - Control

    func start() {
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
            revealAddressesInLogs: settings.logLevel == .debug)

        lastError = nil
        runRequested = true
        startedAt = Date()
        connections.removeAll()
        totals = .init()
        rate = .zero
        rateCalculator.reset()
        refreshAddresses()
        server.start(config)
        startStatsLoop()
        log.add(.info, "서버 시작 요청")
    }

    func stop() {
        server.stop()
        runRequested = false
        startedAt = nil
        statsTask?.cancel()
        statsTask = nil
        connections.removeAll()
        rate = .zero
        socksStatus = .stopped
        httpStatus = .stopped
        log.add(.info, "서버 중지")
    }

    func restartIfRunning() {
        guard runRequested else { return }
        stop()
        start()
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
        case .connectionOpened(let info), .connectionUpdated(let info):
            guard runRequested else { return }
            connections[info.id] = info
        case .connectionClosed(let id):
            connections.removeValue(forKey: id)
        case .log(let level, let message):
            log.add(level, message)
            if level == .error { lastError = message }
        }
    }

    private func networkChanged(_ snapshot: PathSnapshot) {
        refreshAddresses()
        log.add(.info, "네트워크 변경: \(snapshot.summary)")
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
    }
}

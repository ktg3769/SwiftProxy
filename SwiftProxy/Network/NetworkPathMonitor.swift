import Foundation
import Network
import Observation

/// NWPath에서 필요한 값만 뽑은 스냅샷. 모니터 큐에서 만들어 메인 액터로 넘긴다.
struct PathSnapshot: Equatable, Sendable {
    enum Status: String, Sendable {
        case satisfied = "연결됨"
        case unsatisfied = "연결 없음"
        case requiresConnection = "연결 필요"
        case unknown = "알 수 없음"
    }

    var status: Status = .unknown
    var usesWiFi = false
    var usesCellular = false
    var usesWired = false
    var isExpensive = false
    var isConstrained = false
    var supportsIPv4 = false
    var supportsIPv6 = false
    var interfaces: [String] = []

    init() {}

    init(_ path: NWPath) {
        switch path.status {
        case .satisfied: status = .satisfied
        case .unsatisfied: status = .unsatisfied
        case .requiresConnection: status = .requiresConnection
        @unknown default: status = .unknown
        }
        usesWiFi = path.usesInterfaceType(.wifi)
        usesCellular = path.usesInterfaceType(.cellular)
        usesWired = path.usesInterfaceType(.wiredEthernet)
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        supportsIPv4 = path.supportsIPv4
        supportsIPv6 = path.supportsIPv6
        interfaces = path.availableInterfaces.map { "\($0.name) (\(PathSnapshot.typeName($0.type)))" }
    }

    static func typeName(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "Wi-Fi"
        case .cellular: return "셀룰러"
        case .wiredEthernet: return "유선"
        case .loopback: return "루프백"
        case .other: return "기타"
        @unknown default: return "알 수 없음"
        }
    }

    var summary: String {
        guard status == .satisfied else { return status.rawValue }
        var parts: [String] = []
        if usesWiFi { parts.append("Wi-Fi") }
        if usesCellular { parts.append("셀룰러") }
        if usesWired { parts.append("유선") }
        if parts.isEmpty { parts.append("기타") }
        return parts.joined(separator: " + ")
    }
}

/// 기본 경로와 셀룰러 경로를 각각 감시한다. 폴링하지 않고 시스템 콜백만 사용한다.
@MainActor
@Observable
final class NetworkPathMonitor {
    private(set) var current = PathSnapshot()
    /// 기본 경로와 별개로 셀룰러 인터페이스로 나갈 수 있는 경로가 있는지 여부.
    private(set) var cellularAvailable = false
    private(set) var lastChange: Date?

    @ObservationIgnored var onChange: ((PathSnapshot) -> Void)?
    @ObservationIgnored private var mainMonitor: NWPathMonitor?
    @ObservationIgnored private var cellularMonitor: NWPathMonitor?
    @ObservationIgnored private let queue = DispatchQueue(label: "com.taegun.swiftproxy.path")

    func start() {
        guard mainMonitor == nil else { return }

        let main = NWPathMonitor()
        main.pathUpdateHandler = { [weak self] path in
            let snapshot = PathSnapshot(path)
            Task { @MainActor [weak self] in self?.apply(snapshot) }
        }
        main.start(queue: queue)
        mainMonitor = main

        let cellular = NWPathMonitor(requiredInterfaceType: .cellular)
        cellular.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in self?.cellularAvailable = available }
        }
        cellular.start(queue: queue)
        cellularMonitor = cellular
    }

    func stop() {
        mainMonitor?.cancel()
        cellularMonitor?.cancel()
        mainMonitor = nil
        cellularMonitor = nil
    }

    private func apply(_ snapshot: PathSnapshot) {
        let changed = snapshot != current
        current = snapshot
        if changed {
            lastChange = Date()
            onChange?(snapshot)
        }
    }
}

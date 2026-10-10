import Foundation

/// 누가 프록시에 접속할 수 있는지 결정하는 정책.
enum AccessPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 사설 IP 대역(RFC 1918), link-local, loopback, IPv6 ULA/link-local만 허용. 기본값.
    case localNetworkOnly
    /// 사용자가 입력한 CIDR 목록에 포함된 주소만 허용.
    case allowList
    /// 출발지 주소 제한 없음. 명시적으로 켜야 하며 UI에서 경고를 표시한다.
    case anyone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localNetworkOnly: return "로컬 네트워크만"
        case .allowList: return "허용 목록만"
        case .anyone: return "모두 허용 (위험)"
        }
    }
}

enum LogLevel: String, Codable, CaseIterable, Identifiable, Comparable, Sendable {
    case error, warning, info, debug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .error: return "오류"
        case .warning: return "경고"
        case .info: return "정보"
        case .debug: return "디버그"
        }
    }

    private var rank: Int {
        switch self {
        case .error: return 0
        case .warning: return 1
        case .info: return 2
        case .debug: return 3
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
}

/// 디스크(UserDefaults)에 저장되는 설정. 비밀번호는 여기에 저장하지 않고 Keychain에 둔다.
struct ProxySettings: Codable, Equatable, Sendable {
    var socksEnabled: Bool = true
    var socksPort: Int = 1080
    var httpEnabled: Bool = true
    var httpPort: Int = 8080
    var autoStart: Bool = false
    var accessPolicy: AccessPolicy = .localNetworkOnly
    /// CIDR 문자열 목록 (예: "192.168.0.0/24", "fd00::/8").
    var allowList: [String] = []
    var authEnabled: Bool = false
    var authUsername: String = "proxy"
    var logLevel: LogLevel = .info
    /// 통계 갱신 주기(초).
    var statsInterval: Double = 1.0

    static let portRange = 1024...65535
    static let statsIntervalRange = 0.5...10.0

    init() {}

    // 새 필드가 추가돼도 기존 저장값을 읽을 수 있도록 누락된 키는 기본값을 쓴다.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProxySettings()
        socksEnabled = try c.decodeIfPresent(Bool.self, forKey: .socksEnabled) ?? d.socksEnabled
        socksPort = try c.decodeIfPresent(Int.self, forKey: .socksPort) ?? d.socksPort
        httpEnabled = try c.decodeIfPresent(Bool.self, forKey: .httpEnabled) ?? d.httpEnabled
        httpPort = try c.decodeIfPresent(Int.self, forKey: .httpPort) ?? d.httpPort
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? d.autoStart
        accessPolicy = try c.decodeIfPresent(AccessPolicy.self, forKey: .accessPolicy) ?? d.accessPolicy
        allowList = try c.decodeIfPresent([String].self, forKey: .allowList) ?? d.allowList
        authEnabled = try c.decodeIfPresent(Bool.self, forKey: .authEnabled) ?? d.authEnabled
        authUsername = try c.decodeIfPresent(String.self, forKey: .authUsername) ?? d.authUsername
        logLevel = try c.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? d.logLevel
        statsInterval = try c.decodeIfPresent(Double.self, forKey: .statsInterval) ?? d.statsInterval
    }
}

enum SettingsValidator {
    /// 사용자에게 그대로 보여줄 오류 메시지 목록. 비어 있으면 유효하다.
    static func validate(_ s: ProxySettings) -> [String] {
        var errors: [String] = []

        if !s.socksEnabled && !s.httpEnabled {
            errors.append("SOCKS5와 HTTP 중 최소 하나는 켜야 합니다.")
        }
        if s.socksEnabled && !ProxySettings.portRange.contains(s.socksPort) {
            errors.append("SOCKS5 포트는 \(ProxySettings.portRange.lowerBound)~\(ProxySettings.portRange.upperBound) 사이여야 합니다.")
        }
        if s.httpEnabled && !ProxySettings.portRange.contains(s.httpPort) {
            errors.append("HTTP 포트는 \(ProxySettings.portRange.lowerBound)~\(ProxySettings.portRange.upperBound) 사이여야 합니다.")
        }
        if s.socksEnabled && s.httpEnabled && s.socksPort == s.httpPort {
            errors.append("SOCKS5와 HTTP 포트가 같을 수 없습니다.")
        }
        if !ProxySettings.statsIntervalRange.contains(s.statsInterval) {
            errors.append("통계 갱신 주기는 0.5~10초 사이여야 합니다.")
        }

        var invalidRanges: [String] = []
        for entry in s.allowList where IPAddressRange(cidr: entry) == nil {
            invalidRanges.append(entry)
        }
        if !invalidRanges.isEmpty {
            errors.append("잘못된 허용 목록 항목: \(invalidRanges.joined(separator: ", "))")
        }
        if s.accessPolicy == .allowList && s.allowList.isEmpty {
            errors.append("허용 목록 정책을 쓰려면 최소 한 개의 주소 범위가 필요합니다.")
        }

        if s.authEnabled {
            let name = s.authUsername
            if name.isEmpty {
                errors.append("인증 사용자 이름이 비어 있습니다.")
            } else if name.utf8.count > 255 {
                errors.append("인증 사용자 이름은 255바이트 이하여야 합니다 (SOCKS5 RFC 1929 제한).")
            } else if name.contains(":") {
                errors.append("인증 사용자 이름에 ':'를 쓸 수 없습니다 (HTTP Basic 인증 제한).")
            }
        }
        return errors
    }
}

import Foundation

enum ListenerKind: String, Sendable, CaseIterable {
    case socks5
    case http

    var title: String {
        switch self {
        case .socks5: return "SOCKS5"
        case .http: return "HTTP"
        }
    }
}

enum ListenerStatus: Equatable, Sendable {
    case stopped
    case disabled
    case starting
    case ready(port: Int)
    case waiting(String)
    case failed(String)

    var title: String {
        switch self {
        case .stopped: return "중지됨"
        case .disabled: return "꺼짐"
        case .starting: return "시작 중"
        case .ready(let port): return "수신 중 (:\(port))"
        case .waiting(let reason): return "대기: \(reason)"
        case .failed(let reason): return "실패: \(reason)"
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum ConnectionKind: String, Sendable {
    case socks5 = "SOCKS5"
    case socks5UDP = "SOCKS5 UDP"
    case httpConnect = "HTTP CONNECT"
    case httpForward = "HTTP"
    case pending = "협상 중"
}

/// UI에 표시되는 연결 정보. 클라이언트 주소는 이미 마스킹된 문자열만 담는다.
struct ConnectionInfo: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: ConnectionKind
    var clientLabel: String
    var target: String?
    let startedAt: Date
    var bytesUp: UInt64
    var bytesDown: UInt64
}

struct ProxyCredentials: Equatable, Sendable {
    let username: String
    let password: String
}

enum ProxyEvent: Sendable {
    case listener(ListenerKind, ListenerStatus)
    case connectionOpened(ConnectionInfo)
    case connectionUpdated(ConnectionInfo)
    case connectionClosed(UUID)
    /// 접근 정책·연결 한도·셀룰러 인터페이스 때문에 받자마자 닫은 연결.
    case connectionRejected
    case log(LogLevel, String)
}

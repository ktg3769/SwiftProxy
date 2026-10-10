import Foundation
import Network

/// 리스너 종류별 연결 처리기를 만든다.
/// Phase 2: 아직 SOCKS5/HTTP 처리기가 없으므로 nil을 반환하고, 매니저가 연결을 닫고 로그를 남긴다.
/// Phase 3에서 SOCKS5Handler / HTTPProxyHandler를 여기서 생성한다.
enum ProxyHandlerFactory {
    static func make(kind: ListenerKind, connection: NWConnection, id: UUID,
                     manager: ProxyServerManager) -> ProxyConnectionHandler? {
        switch kind {
        case .socks5:
            return nil
        case .http:
            return nil
        }
    }
}

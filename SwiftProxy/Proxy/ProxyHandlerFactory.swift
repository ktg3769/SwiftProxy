import Foundation
import Network

/// 리스너 종류별 연결 처리기를 만든다. manager.queue 위에서 호출된다.
enum ProxyHandlerFactory {
    static func make(kind: ListenerKind, connection: NWConnection, id: UUID,
                     manager: ProxyServerManager) -> ProxyConnectionHandler? {
        guard let configuration = manager.configuration else { return nil }
        let label = ProxyServerManager.hostString(connection.endpoint).map { manager.redact($0) } ?? "알 수 없음"
        return ProxySession(kind: kind, client: connection, id: id, manager: manager,
                            configuration: configuration, clientLabel: label)
    }
}

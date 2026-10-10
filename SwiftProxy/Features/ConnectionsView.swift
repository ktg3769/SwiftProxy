import SwiftUI

struct ConnectionsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        NavigationStack {
            Group {
                if app.connections.isEmpty {
                    ContentUnavailableView(
                        "연결 없음",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text(app.runRequested ? "아직 들어온 연결이 없습니다." : "서버가 중지되어 있습니다."))
                } else {
                    List {
                        ForEach(app.sortedConnections) { info in
                            ConnectionRow(info: info)
                                .swipeActions {
                                    Button("종료", role: .destructive) {
                                        app.closeConnection(info.id)
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle("연결 (\(app.activeConnectionCount))")
            .toolbar {
                if !app.connections.isEmpty {
                    Button("모두 종료", role: .destructive) { app.closeAllConnections() }
                }
            }
        }
    }
}

private struct ConnectionRow: View {
    let info: ConnectionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(info.kind.rawValue)
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.2), in: Capsule())
                Text(info.target ?? "대상 미정")
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 12) {
                Text(info.clientLabel)
                TimelineView(.periodic(from: info.startedAt, by: 1)) { context in
                    Text(Formatters.duration(context.date.timeIntervalSince(info.startedAt)))
                }
                Text("↑ \(Formatters.bytes(info.bytesUp))")
                Text("↓ \(Formatters.bytes(info.bytesDown))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }
}

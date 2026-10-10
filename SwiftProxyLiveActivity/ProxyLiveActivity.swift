import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SwiftProxyLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        ProxyLiveActivityWidget()
    }
}

struct ProxyLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ProxyActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(ProxyActivityAttributes.deepLink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        StatusLabel(context: context)
                        if let socks = context.attributes.socksPort {
                            Text("SOCKS5 :\(socks)").font(.caption2).foregroundStyle(.secondary)
                        }
                        if let http = context.attributes.httpPort {
                            Text("HTTP :\(http)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("연결 \(context.state.connections)").font(.caption.bold())
                        if context.state.isRunning && !context.isStale {
                            Text(context.attributes.startedAt, style: .timer)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        HStack {
                            Label(Formatters.rate(context.state.upRate), systemImage: "arrow.up")
                            Spacer()
                            Label(Formatters.rate(context.state.downRate), systemImage: "arrow.down")
                        }
                        .font(.caption.monospacedDigit())
                        HStack {
                            Text("누적 ↑\(Formatters.bytes(context.state.totalUp)) ↓\(Formatters.bytes(context.state.totalDown))")
                            Spacer()
                            Text(context.state.network)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        if let error = context.state.error {
                            Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1)
                        }
                        if context.isStale {
                            Text("앱에서 상태를 확인할 수 없음").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: symbol(context))
                    .foregroundStyle(color(context))
            } compactTrailing: {
                Text(context.isStale ? "?" : "\(context.state.connections)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(color(context))
            } minimal: {
                Image(systemName: symbol(context))
                    .foregroundStyle(color(context))
            }
            .widgetURL(ProxyActivityAttributes.deepLink)
            .keylineTint(color(context))
        }
    }
}

private func symbol(_ context: ActivityViewContext<ProxyActivityAttributes>) -> String {
    if context.isStale { return "questionmark.circle" }
    if context.state.error != nil { return "exclamationmark.triangle.fill" }
    return context.state.isRunning ? "network" : "network.slash"
}

private func color(_ context: ActivityViewContext<ProxyActivityAttributes>) -> Color {
    if context.isStale { return .orange }
    if context.state.error != nil { return .red }
    return context.state.isRunning ? .green : .gray
}

private struct StatusLabel: View {
    let context: ActivityViewContext<ProxyActivityAttributes>

    var body: some View {
        Label(title, systemImage: symbol(context))
            .font(.caption.bold())
            .foregroundStyle(color(context))
    }

    private var title: String {
        if context.isStale { return "확인 불가" }
        if context.state.error != nil { return "오류" }
        return context.state.isRunning ? "실행 중" : "중지됨"
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<ProxyActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                StatusLabel(context: context)
                Spacer()
                Text("연결 \(context.state.connections)")
                    .font(.subheadline.bold().monospacedDigit())
            }
            HStack {
                Text(context.state.network)
                Spacer()
                Text("↑\(Formatters.rate(context.state.upRate))  ↓\(Formatters.rate(context.state.downRate))")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let error = context.state.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            } else if context.isStale {
                Text("마지막 갱신 \(context.state.updatedAt.formatted(date: .omitted, time: .shortened)) · 앱이 일시 중지되었거나 종료되었을 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else {
                Text(context.state.backgroundMode)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

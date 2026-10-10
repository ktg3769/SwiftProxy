import SwiftUI
import UIKit

struct DashboardView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        NavigationStack {
            List {
                if let notice = app.sessionNotice {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(notice, systemImage: "info.circle.fill")
                                .foregroundStyle(.orange)
                                .font(.callout)
                            Button("확인") { app.dismissNotice() }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                statusSection
                Section {
                    LabeledContent("실행 방식", value: app.backgroundModeTitle)
                    LabeledContent("백그라운드 작업", value: app.backgroundStatus.title)
                    if app.runRequested && app.backgroundStatus != .running && app.backgroundStatus != .submitted {
                        Button("백그라운드 작업 다시 요청") { app.requestBackgroundTask() }
                    }
                } header: {
                    Text("백그라운드")
                } footer: {
                    Text("iOS 26 백그라운드 작업(BGContinuedProcessingTask)이 '실행 중'이어야 앱을 나가도 연결을 계속 받습니다. 앱은 서버를 스스로 끄지 않습니다. 작업이 없거나 iOS가 작업을 끝내면 iOS가 앱을 일시 중지해 그동안 연결을 못 받고, 앱으로 돌아오면 리스너를 다시 열고 작업을 다시 요청합니다.")
                }
                if let error = app.lastError {
                    Section("오류") {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
                trafficSection
                listenerSection
                addressSection
                Section("네트워크") {
                    LabeledContent("현재 경로", value: app.pathMonitor.current.summary)
                    LabeledContent("셀룰러 경로", value: app.pathMonitor.cellularAvailable ? "사용 가능" : "없음")
                }
            }
            .navigationTitle("SwiftProxy")
            .refreshable { app.refreshAddresses() }
        }
    }

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.statusTitle).font(.headline)
                    if let startedAt = app.startedAt {
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            Text("실행 시간 \(Formatters.duration(context.date.timeIntervalSince(startedAt)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                Spacer()
                Button {
                    app.runRequested ? app.stop() : app.start()
                } label: {
                    Text(app.runRequested ? "중지" : "시작")
                        .frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent)
                .tint(app.runRequested ? .red : .green)
            }
            .padding(.vertical, 4)
        }
    }

    private var trafficSection: some View {
        Section("트래픽") {
            LabeledContent("현재 연결", value: "\(app.activeConnectionCount)")
            LabeledContent("업로드 속도", value: Formatters.rate(app.rate.up))
            LabeledContent("다운로드 속도", value: Formatters.rate(app.rate.down))
            LabeledContent("누적 업로드", value: Formatters.bytes(app.totals.up))
            LabeledContent("누적 다운로드", value: Formatters.bytes(app.totals.down))
        }
        .monospacedDigit()
    }

    private var listenerSection: some View {
        let s = app.settingsStore.settings
        return Section("리스너") {
            LabeledContent("SOCKS5 (\(s.socksEnabled ? String(s.socksPort) : "꺼짐"))", value: app.socksStatus.title)
            LabeledContent("HTTP (\(s.httpEnabled ? String(s.httpPort) : "꺼짐"))", value: app.httpStatus.title)
            LabeledContent("접근 정책", value: s.accessPolicy.title)
        }
    }

    private var addressSection: some View {
        let s = app.settingsStore.settings
        return Section {
            if app.runRequested {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("고정 이름 (mDNS)").font(.caption).foregroundStyle(.secondary)
                        Text("권장")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.green.opacity(0.25), in: Capsule())
                    }
                    if s.socksEnabled { copyRow("SOCKS5", "\(MDNSAlias.displayName):\(s.socksPort)") }
                    if s.httpEnabled { copyRow("HTTP", "\(MDNSAlias.displayName):\(s.httpPort)") }
                }
            }
            if app.lanAddresses.isEmpty {
                Text("Wi-Fi 또는 개인용 핫스팟 주소가 없습니다.")
                    .foregroundStyle(.secondary)
            }
            ForEach(app.lanAddresses) { address in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(address.kindLabel) · \(address.name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if address.isPreferredForHotspot {
                            Text("권장")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.green.opacity(0.25), in: Capsule())
                        }
                    }
                    if s.socksEnabled {
                        copyRow("SOCKS5", endpoint(address, s.socksPort))
                    }
                    if s.httpEnabled {
                        copyRow("HTTP", endpoint(address, s.httpPort))
                    }
                }
            }
        } header: {
            Text("접속 주소")
        } footer: {
            Text("Shadowrocket 등에는 서버 주소로 swiftproxy.local을 넣으면 IPv6 주소가 바뀌어도 그대로 접속됩니다(앱이 현재 주소로 자동 갱신). 이름이 안 되면 '권장' IPv6 주소를 쓰세요. iOS 핫스팟에서는 172.20.10.1(IPv4)로 이 앱에 접속이 안 될 수 있습니다. IPv6 주소는 셀룰러가 다시 연결되면 바뀔 수 있으니, 접속이 안 되면 여기서 새 주소를 확인하세요.")
        }
    }

    private func copyRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline).frame(width: 64, alignment: .leading)
            Text(value).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button {
                UIPasteboard.general.string = value
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(label) 주소 복사")
        }
    }

    private func endpoint(_ address: InterfaceAddress, _ port: Int) -> String {
        address.isIPv6 ? "[\(address.address)]:\(port)" : "\(address.address):\(port)"
    }

    private var statusColor: Color {
        if app.isRunning { return .green }
        if app.runRequested { return app.lastError == nil ? .yellow : .red }
        return .gray
    }
}

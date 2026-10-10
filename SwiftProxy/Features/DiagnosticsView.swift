import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @Environment(AppState.self) private var app
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                networkSection
                listenerSection
                interfaceSection
                errorSection
                Section {
                    Button(app.outboundRunning ? "테스트 중…" : "외부 연결 테스트") { app.runOutboundTest() }
                        .disabled(app.outboundRunning)
                    ForEach(app.outboundResults) { result in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(result.address, systemImage: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.success ? .green : .red)
                            Text(result.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("외부 연결")
                } footer: {
                    Text("앱이 셀룰러로 인터넷에 나갈 수 있는지 확인합니다. 앱을 켤 때 자동으로 한 번 실행되며, 이때 iOS 설정 > 셀룰러 목록에 SwiftProxy가 등록됩니다.")
                }

                Section {
                    Button(app.selfTestRunning ? "테스트 중…" : "SOCKS5 접속 테스트") { app.runSelfTest() }
                        .disabled(app.selfTestRunning)
                    ForEach(app.selfTestResults) { result in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(result.address, systemImage: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.success ? .green : .red)
                            Text(result.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("자체 테스트")
                } footer: {
                    Text("이 iPhone의 Wi-Fi·핫스팟 주소로 자기 SOCKS5 포트에 접속해 봅니다. 성공하면 같은 네트워크의 다른 기기도 그 주소로 접속할 수 있어야 합니다. UDP 중계에는 설정 > 개인정보 보호 및 보안 > 로컬 네트워크에서 SwiftProxy 허용이 필요합니다.")
                }
                Section {
                    Button("전체 로그 복사") {
                        UIPasteboard.general.string = app.log.exportText()
                        copied = true
                    }
                    NavigationLink("전체 로그 보기 (\(app.log.entries.count))") {
                        LogListView()
                    }
                } header: {
                    Text("로그")
                } footer: {
                    Text(copied ? "복사했습니다. 그대로 붙여넣어 공유하세요." : "연결 수락, 요청 대상, 대상 연결 성공/실패, 백그라운드 전환이 기록됩니다. 클라이언트 IP는 일부 가려집니다.")
                }

                Section {
                    LabeledContent("상태", value: app.backgroundStatus.title)
                    LabeledContent("Bundle ID", value: BackgroundTaskManager.runtimeBundleID)
                    LabeledContent("허용 식별자", value: BackgroundTaskManager.permittedPatterns.joined(separator: "\n"))
                    LabeledContent("Bundle ID 일치",
                                   value: BackgroundTaskManager.permittedPatternsMatchBundle ? "예" : "아니오 (작업이 실행되지 않음)")
                } header: {
                    Text("백그라운드 작업")
                } footer: {
                    Text("허용 식별자가 현재 Bundle ID로 시작하지 않으면 iOS는 작업을 받기만 하고 실행하지 않습니다. 재서명 앱(ESign 등)에서 Bundle ID를 바꿔 서명하면 이렇게 됩니다.")
                }

                Section("버전") {
                    LabeledContent("앱", value: Self.appVersion)
                    LabeledContent("iOS", value: UIDevice.current.systemVersion)
                    LabeledContent("기기", value: UIDevice.current.model)
                }
            }
            .navigationTitle("진단")
            .refreshable { app.refreshAddresses() }
        }
    }

    private var networkSection: some View {
        let p = app.pathMonitor.current
        return Section("네트워크 경로") {
            LabeledContent("상태", value: p.status.rawValue)
            LabeledContent("기본 경로", value: p.summary)
            LabeledContent("셀룰러 경로", value: app.pathMonitor.cellularAvailable ? "사용 가능" : "없음")
            LabeledContent("데이터 비용 높음", value: p.isExpensive ? "예" : "아니오")
            LabeledContent("저데이터 모드", value: p.isConstrained ? "예" : "아니오")
            LabeledContent("IPv4 / IPv6", value: "\(p.supportsIPv4 ? "O" : "X") / \(p.supportsIPv6 ? "O" : "X")")
            if let changed = app.pathMonitor.lastChange {
                LabeledContent("마지막 변경", value: changed.formatted(date: .omitted, time: .standard))
            }
        }
    }

    private var listenerSection: some View {
        let s = app.settingsStore.settings
        return Section {
            LabeledContent("SOCKS5 :\(s.socksPort)", value: s.socksEnabled ? app.socksStatus.title : "꺼짐")
            LabeledContent("HTTP :\(s.httpPort)", value: s.httpEnabled ? app.httpStatus.title : "꺼짐")
            LabeledContent("접근 정책", value: s.accessPolicy.title)
            LabeledContent("인증", value: s.authEnabled ? "사용 (\(s.authUsername))" : "사용 안 함")
            LabeledContent("누적 수락 연결", value: "\(app.acceptedTotal)")
            LabeledContent("누적 거부 연결", value: "\(app.rejectedTotal)")
        } header: {
            Text("리스너")
        } footer: {
            Text("바인딩 정책: BSD 소켓으로 0.0.0.0(IPv4)과 ::(IPv6)에서 수신합니다(a-shell 서버와 같은 방식). 셀룰러 인터페이스(pdp_ip*) 주소로 들어온 연결은 수락 직후 닫습니다. '로컬 네트워크만' 정책에서는 연결을 받을 때 출발지 IP가 사설 대역인지 검사합니다. IPv6 수신은 실기기에서 아직 검증하지 않았습니다.")
        }
    }

    private var interfaceSection: some View {
        Section("인터페이스 주소") {
            let all = InterfaceAddresses.all()
            if all.isEmpty {
                Text("활성 인터페이스 없음").foregroundStyle(.secondary)
            }
            ForEach(all) { item in
                LabeledContent("\(item.name) · \(item.kindLabel)") {
                    Text(item.address)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var errorSection: some View {
        Section("최근 오류/경고") {
            let problems = app.log.recentProblems
            if problems.isEmpty {
                Text("없음").foregroundStyle(.secondary)
            }
            ForEach(problems) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.message).font(.callout)
                    Text("\(entry.level.title) · \(entry.date.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(entry.level == .error ? .red : .orange)
                }
            }
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

struct LogListView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        List {
            ForEach(app.log.entries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.message)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("\(entry.level.title) · \(entry.date.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(color(entry.level))
                }
            }
        }
        .navigationTitle("로그")
        .toolbar {
            Button("복사") { UIPasteboard.general.string = app.log.exportText() }
        }
    }

    private func color(_ level: LogLevel) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        case .debug: return .gray
        }
    }
}

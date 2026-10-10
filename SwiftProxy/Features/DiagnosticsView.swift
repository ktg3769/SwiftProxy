import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        NavigationStack {
            List {
                networkSection
                listenerSection
                interfaceSection
                errorSection
                Section("자체 테스트") {
                    Text("아직 구현되지 않음 (Phase 5에서 추가 예정)")
                        .foregroundStyle(.secondary)
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
        } header: {
            Text("리스너")
        } footer: {
            Text("바인딩 정책: 모든 로컬 주소(IPv4/IPv6)에서 수신하되 셀룰러 인터페이스는 제외합니다. '로컬 네트워크만' 정책에서는 시스템 수준(acceptLocalOnly)과 앱 수준(사설 IP 대역 검사) 두 단계로 제한합니다. IPv6 수신은 실기기에서 아직 검증하지 않았습니다.")
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

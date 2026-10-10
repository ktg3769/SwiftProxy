import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppState.self) private var app

    @State private var draft = ProxySettings()
    @State private var allowListText = ""
    @State private var errors: [String] = []
    @State private var saved = false
    @State private var revealPassword = false
    @State private var customPassword = ""
    @State private var passwordMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if !errors.isEmpty {
                    Section {
                        ForEach(errors, id: \.self) { error in
                            Label(error, systemImage: "xmark.octagon.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }

                Section("포트") {
                    Toggle("SOCKS5", isOn: $draft.socksEnabled)
                    if draft.socksEnabled {
                        portField("SOCKS5 포트", value: $draft.socksPort)
                    }
                    Toggle("HTTP 프록시", isOn: $draft.httpEnabled)
                    if draft.httpEnabled {
                        portField("HTTP 포트", value: $draft.httpPort)
                    }
                }

                accessSection
                authSection

                Section {
                    Picker("외부 연결 경로", selection: $draft.outboundRoute) {
                        ForEach(OutboundRoute.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("외부 연결")
                } footer: {
                    Text("'셀룰러만'은 프록시가 대상 서버로 나가는 연결에 셀룰러 인터페이스를 요구합니다 (Network.framework requiredInterfaceType). Wi-Fi에 연결된 상태에서도 셀룰러로 나가게 하려는 용도이며, 셀룰러가 없으면 연결이 실패합니다. 이 앱의 프록시 연결에만 적용되고 iPhone의 다른 트래픽에는 영향을 주지 않습니다. 실기기 검증 전입니다.")
                }

                Section {
                    Toggle("백그라운드 작업 사용 (iOS 26)", isOn: $draft.useContinuedProcessing)
                    Toggle("Live Activity 표시", isOn: $draft.showLiveActivity)
                } header: {
                    Text("백그라운드 · Live Activity")
                } footer: {
                    Text("백그라운드 작업은 시작 버튼을 직접 눌렀을 때만 요청됩니다(자동 시작 시에는 요청되지 않음). 이 작업이 시스템 Live Activity를 따로 표시하므로, 앱 자체 Live Activity와 함께 두 개가 보일 수 있습니다. Live Activity 표시 자체는 서버를 살려 두지 않습니다.")
                }

                Section {
                    Toggle("앱 실행 시 자동 시작", isOn: $draft.autoStart)
                    Picker("로그 수준", selection: $draft.logLevel) {
                        ForEach(LogLevel.allCases) { Text($0.title).tag($0) }
                    }
                    Stepper(value: $draft.statsInterval, in: ProxySettings.statsIntervalRange, step: 0.5) {
                        LabeledContent("통계 갱신 주기", value: String(format: "%.1f초", draft.statsInterval))
                    }
                } header: {
                    Text("동작")
                } footer: {
                    Text("로그 수준이 '디버그'일 때만 클라이언트 IP가 전체로 기록됩니다. 그 외에는 일부가 가려집니다. 갱신 주기를 짧게 하면 배터리 사용이 늘어납니다.")
                }
            }
            .navigationTitle("설정")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(saved ? "저장됨" : "저장") { save() }
                        .disabled(draft == app.settingsStore.settings && allowListText == currentAllowListText)
                }
            }
            .onAppear(perform: load)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var accessSection: some View {
        Section {
            Picker("접근 정책", selection: $draft.accessPolicy) {
                ForEach(AccessPolicy.allCases) { Text($0.title).tag($0) }
            }
            if draft.accessPolicy == .allowList {
                TextField("CIDR 목록 (쉼표 또는 줄바꿈 구분)", text: $allowListText, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(2...6)
            }
            if draft.accessPolicy == .anyone {
                Label("출발지 주소를 검사하지 않습니다. 인증 없이 사용하면 같은 네트워크의 누구나 이 iPhone을 경유해 인터넷에 접속할 수 있습니다.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        } header: {
            Text("접근 제어")
        } footer: {
            Text("'로컬 네트워크만'은 10.x, 172.16-31.x, 192.168.x, 169.254.x, 100.64/10, IPv6 ULA·link-local 주소만 허용합니다.")
        }
    }

    private var authSection: some View {
        Section {
            Toggle("인증 사용", isOn: $draft.authEnabled)
            if draft.authEnabled {
                TextField("사용자 이름", text: $draft.authUsername)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if app.settingsStore.hasPassword {
                    HStack {
                        Text(revealPassword ? (app.settingsStore.password() ?? "") : "••••••••••••")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button(revealPassword ? "숨기기" : "보기") { revealPassword.toggle() }
                            .buttonStyle(.borderless)
                        Button {
                            UIPasteboard.general.string = app.settingsStore.password()
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                    }
                    Button("무작위 비밀번호 재생성") {
                        app.settingsStore.regeneratePassword()
                        passwordMessage = "새 비밀번호가 생성되었습니다. 서버 재시작 후 적용됩니다."
                    }
                } else {
                    Text("저장하면 무작위 비밀번호가 생성됩니다.")
                        .foregroundStyle(.secondary)
                }
                SecureField("직접 지정 (8자 이상)", text: $customPassword)
                    .textInputAutocapitalization(.never)
                if !customPassword.isEmpty {
                    Button("이 비밀번호로 설정") {
                        passwordMessage = app.settingsStore.setPassword(customPassword) ?? "비밀번호가 변경되었습니다."
                        customPassword = ""
                    }
                }
                if let passwordMessage {
                    Text(passwordMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("인증")
        } footer: {
            Text("SOCKS5는 사용자 이름/비밀번호(RFC 1929), HTTP는 Proxy-Authorization Basic 방식입니다. 둘 다 평문으로 전송되므로 신뢰할 수 있는 네트워크에서만 사용하세요. 비밀번호는 기기 Keychain에만 저장됩니다.")
        }
    }

    private func portField(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number.grouping(.never))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        }
    }

    private var currentAllowListText: String {
        app.settingsStore.settings.allowList.joined(separator: "\n")
    }

    private func load() {
        draft = app.settingsStore.settings
        allowListText = currentAllowListText
        errors = []
        saved = false
    }

    private func save() {
        var candidate = draft
        candidate.allowList = allowListText
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        candidate.authUsername = candidate.authUsername.trimmingCharacters(in: .whitespaces)

        errors = app.applySettings(candidate)
        if errors.isEmpty {
            load()
            saved = true
        }
    }
}

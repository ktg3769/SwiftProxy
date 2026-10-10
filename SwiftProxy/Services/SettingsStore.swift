import Foundation
import Observation

@MainActor
@Observable
final class SettingsStore {
    private(set) var settings: ProxySettings
    private(set) var hasPassword: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "proxySettings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(ProxySettings.self, from: data) {
            settings = decoded
        } else {
            settings = ProxySettings()
        }
        hasPassword = KeychainStore.readPassword() != nil
    }

    /// 검증을 통과한 경우에만 저장한다. 실패하면 오류 메시지를 돌려준다.
    @discardableResult
    func apply(_ draft: ProxySettings) -> [String] {
        let errors = SettingsValidator.validate(draft)
        guard errors.isEmpty else { return errors }
        // 인증을 켰는데 비밀번호가 없으면 무작위 비밀번호를 만든다. 고정 기본 비밀번호는 쓰지 않는다.
        if draft.authEnabled && KeychainStore.readPassword() == nil {
            guard KeychainStore.savePassword(KeychainStore.generatePassword()) else {
                return ["비밀번호를 Keychain에 저장하지 못했습니다."]
            }
        }
        settings = draft
        persist()
        hasPassword = KeychainStore.readPassword() != nil
        return []
    }

    func password() -> String? { KeychainStore.readPassword() }

    @discardableResult
    func regeneratePassword() -> Bool {
        let ok = KeychainStore.savePassword(KeychainStore.generatePassword())
        hasPassword = KeychainStore.readPassword() != nil
        return ok
    }

    @discardableResult
    func setPassword(_ value: String) -> String? {
        guard value.utf8.count >= 8 else { return "비밀번호는 8자 이상이어야 합니다." }
        guard value.utf8.count <= 255 else { return "비밀번호는 255바이트 이하여야 합니다." }
        guard KeychainStore.savePassword(value) else { return "Keychain 저장에 실패했습니다." }
        hasPassword = true
        return nil
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}

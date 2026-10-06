import Foundation
import Testing
@testable import clawchat

struct UserSignInCapabilityTests {
    @Test func serverCapabilityOverridesLegacyIdentityInferenceAndSurvivesStorage() throws {
        for enabled in [true, false] {
            let data = try JSONSerialization.data(withJSONObject: [
                "id": UUID().uuidString, "username": "phone-user", "email": "",
                "phone": "+8613800138000", "has_password": enabled
            ])
            let user = try JSONDecoder().decode(User.self, from: data)
            #expect(user.canChangePassword == enabled)
            let stored = try JSONEncoder().encode(user)
            #expect(try JSONDecoder().decode(User.self, from: stored).hasPassword == enabled)
        }
    }

    @Test func legacyAccountsKeepWorkingWithoutInventingAPhonePassword() throws {
        for (email, phone, expected) in [("", "+8613800138000", false), ("user@example.invalid", "", true), ("user@example.invalid", "+8613800138000", true)] {
            let data = try JSONSerialization.data(withJSONObject: [
                "id": UUID().uuidString, "username": "legacy", "email": email, "phone": phone
            ])
            let user = try JSONDecoder().decode(User.self, from: data)
            #expect(user.hasPassword == nil)
            #expect(user.canChangePassword == expected)
        }
    }

    @MainActor @Test func passwordlessSettingsRejectSubmissionBeforeStartingARequest() async {
        let user = User(id: UUID(), username: "phone-user", email: "", phone: "+8613800138000", hasPassword: false)
        let model = SettingsViewModel(previewUser: user)
        do {
            try await model.changePassword(currentPassword: "unused", newPassword: "unused-new-password")
            Issue.record("Passwordless account unexpectedly submitted a password change")
        } catch {
            #expect(error.localizedDescription == L10n.t("此账号未设置密码，请使用原登录方式。", "This account has no password. Use its existing sign-in method."))
            #expect(!model.isChangingPassword)
            #expect(model.currentUser?.hasPassword == false)
        }
    }
}

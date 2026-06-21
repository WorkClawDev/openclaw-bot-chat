import SwiftUI
import UserNotifications
import PhotosUI
import UIKit

extension SettingsView {
    func initialLoadIfNeeded() async {
        guard !didInitialLoad else { return }
        didInitialLoad = true
        syncProfileDraftsIfNeeded()
        await refreshNotificationAuthorization()
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestAuthenticated") {
            return
        }
#endif
        await viewModel.fetchProfile()
        syncProfileDraftsIfNeeded()
    }

    func refreshAll() async {
        await refreshNotificationAuthorization()
        await viewModel.fetchProfile()
        syncProfileDraftsIfNeeded()
    }

    func syncProfileDraftsIfNeeded() {
        guard !isEditingProfile, let user = resolvedUser else { return }
        nicknameDraft = displayName(for: user)
        avatarURLDraft = avatarURL(for: user) ?? ""
    }

    func startProfileEditing(using user: User) {
        nicknameDraft = displayName(for: user)
        avatarURLDraft = avatarURL(for: user) ?? ""
        selectedAvatarItem = nil
        pendingAvatarImage = nil
        profileErrorMessage = nil
        isEditingProfile = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focusNicknameField = true
        }
    }

    func cancelProfileEditing() {
        syncProfileDraftsIfNeeded()
        selectedAvatarItem = nil
        pendingAvatarImage = nil
        profileErrorMessage = nil
        isEditingProfile = false
    }

    var profileAvatarSelection: Binding<PhotosPickerItem?> {
        Binding(
            get: { selectedAvatarItem },
            set: { item in
                selectedAvatarItem = item
                guard let item else { return }
                Task { await prepareProfileAvatarCrop(from: item) }
            }
        )
    }

    func prepareProfileAvatarCrop(from item: PhotosPickerItem) async {
        guard !isUploadingAvatar else { return }
        isUploadingAvatar = true
        profileErrorMessage = nil
        defer {
            isUploadingAvatar = false
            selectedAvatarItem = nil
        }

        do {
            pendingAvatarImage = PendingAvatarImage(image: try await AvatarUploadService.loadImage(from: item))
        } catch {
            profileErrorMessage = SettingsViewModel.message(from: error)
        }
    }

    func uploadProfileAvatarImage(_ image: UIImage) async {
        guard !isUploadingAvatar else { return }
        isUploadingAvatar = true
        profileErrorMessage = nil
        defer {
            isUploadingAvatar = false
        }

        do {
            let prefix = resolvedUser?.username ?? "profile"
            avatarURLDraft = try await AvatarUploadService.uploadAvatarImage(image, fileNamePrefix: prefix)
            presentToast(L10n.t("头像已上传", "Avatar uploaded"))
        } catch {
            profileErrorMessage = SettingsViewModel.message(from: error)
        }
    }

    func saveProfileChanges(for user: User) async {
        let trimmedNickname = nicknameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAvatarURL = avatarURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedNickname.isEmpty {
            profileErrorMessage = L10n.t("显示名称不能为空", "Display name cannot be empty")
            return
        }
        do {
            _ = try await viewModel.updateProfile(nickname: trimmedNickname, avatarURL: trimmedAvatarURL)
            withAnimation { isEditingProfile = false }
            presentToast(L10n.t("个人资料已更新", "Profile updated"))
        } catch {
            profileErrorMessage = SettingsViewModel.message(from: error)
        }
    }

    func submitPasswordChange() async {
        passwordErrorMessage = nil
        if newPassword.count < 8 {
            passwordErrorMessage = L10n.t("新密码至少需要 8 个字符", "New password must be at least 8 characters")
            return
        }
        if newPassword != confirmPassword {
            passwordErrorMessage = L10n.t("两次输入的新密码不一致", "New passwords do not match")
            return
        }
        do {
            try await viewModel.changePassword(currentPassword: currentPassword, newPassword: newPassword)
            resetPasswordForm()
            withAnimation { showPasswordEditor = false }
            presentToast(L10n.t("密码已更新", "Password updated"))
        } catch {
            passwordErrorMessage = SettingsViewModel.message(from: error)
        }
    }

    func resetPasswordForm() {
        currentPassword = ""
        newPassword = ""
        confirmPassword = ""
        passwordErrorMessage = nil
    }

    func refreshNotificationAuthorization() async {
        let settings = await notificationSettings()
        notificationAuthorizationStatus = settings.authorizationStatus
        if !hasNotificationPermission { botNotificationsEnabled = false }
    }

    func updateNotifications(enabled: Bool) async {
        if !enabled {
            botNotificationsEnabled = false
            presentToast(L10n.t("通知已关闭", "Notifications turned off"))
            return
        }
        if hasNotificationPermission {
            botNotificationsEnabled = true
            presentToast(L10n.t("通知已开启", "Notifications turned on"))
            return
        }
        let granted = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refreshNotificationAuthorization()
        if granted == true {
            botNotificationsEnabled = true
            presentToast(L10n.t("通知已开启", "Notifications turned on"))
        } else {
            botNotificationsEnabled = false
            presentToast(L10n.t("未获得通知权限", "Notification permission was not granted"), isError: true)
        }
    }

    func presentToast(_ message: String, isError: Bool = false) {
        let payload = SettingsToastPayload(message: message, isError: isError)
        withAnimation(.spring(response: 0.3)) { toast = payload }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if toast?.id == payload.id { withAnimation { toast = nil } }
        }
    }

    var normalizedAvatarDraft: String? {
        let trimmed = avatarURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func effectiveDraftName(for user: User) -> String {
        let trimmed = nicknameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? user.username : trimmed
    }

    func displayName(for user: User) -> String {
        user.nickname?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? user.nickname! : user.username
    }

    func avatarURL(for user: User) -> String? {
        user.avatarUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? user.avatar?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func dateText(_ date: Date?) -> String? {
        guard let date else { return nil }
        return Self.dateFormatter.string(from: date)
    }

    func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    var notificationSubtitle: String {
        switch notificationAuthorizationStatus {
        case .authorized, .provisional: return botNotificationsEnabled ? L10n.t("已开启", "On") : L10n.t("已允许", "Allowed")
        case .denied: return L10n.t("已阻止", "Blocked")
        default: return L10n.t("已关闭", "Off")
        }
    }

    var imageUploadQualitySubtitle: String {
        switch imageUploadQuality {
        case "Original":
            return L10n.t("原图", "Original")
        case "Compressed":
            return L10n.t("小图", "Small")
        default:
            return L10n.t("均衡", "Balanced")
        }
    }

    var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version?.isEmpty == false ? version : nil, build?.isEmpty == false ? build : nil) {
        case let (.some(version), .some(build)):
            return L10n.t("版本 \(version) (\(build))", "Version \(version) (\(build))")
        case let (.some(version), .none):
            return L10n.t("版本 \(version)", "Version \(version)")
        case let (.none, .some(build)):
            return L10n.t("构建 \(build)", "Build \(build)")
        default:
            return L10n.t("OpenClaw 机器人聊天", "OpenClaw Bot Chat")
        }
    }

    var realtimeConnectionText: String {
        switch realtimeService.connectionState {
        case .idle:
            return L10n.t("空闲", "Idle")
        case .connecting:
            return L10n.t("连接中", "Connecting")
        case .connected:
            return L10n.t("已连接", "Connected")
        case .disconnected:
            return L10n.t("未连接", "Disconnected")
        }
    }

    var realtimeConnectionIcon: String {
        switch realtimeService.connectionState {
        case .connected:
            return "bolt.horizontal.circle.fill"
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .disconnected:
            return "wifi.slash"
        case .idle:
            return "power"
        }
    }

    static let imageUploadQualityOptions = ["Compressed", "Balanced", "Original"]
    static func localizedImageUploadQuality(_ quality: String) -> String {
        switch quality {
        case "Compressed":
            return L10n.t("压缩", "Compressed")
        case "Original":
            return L10n.t("原图", "Original")
        default:
            return L10n.t("均衡", "Balanced")
        }
    }
    static let coralDanger = Color(red: 248 / 255, green: 113 / 255, blue: 113 / 255)

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy"
        return f
    }()
}

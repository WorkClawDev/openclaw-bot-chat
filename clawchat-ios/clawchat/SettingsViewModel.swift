import Combine
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    private let accountScope = AccountSession.shared.snapshot
    @Published var currentUser: User?
    @Published var isLoading = false
    @Published var isSavingProfile = false
    @Published var isChangingPassword = false
    @Published var loadErrorMessage: String?

    init(previewUser: User? = nil) {
        self.currentUser = previewUser ?? AuthManager.shared.currentUser
    }

    func fetchProfile() async {
        guard AccountSession.shared.isCurrent(accountScope), !isLoading else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let user = try await APIClient.shared.fetchCurrentUserValue()
            guard AccountSession.shared.isCurrent(accountScope) else { return }
            currentUser = user
            AuthManager.shared.currentUser = user
            loadErrorMessage = nil
        } catch {
            loadErrorMessage = Self.message(from: error)
        }
    }

    func updateProfile(nickname: String, avatarURL: String) async throws -> User {
        guard AccountSession.shared.isCurrent(accountScope) else { throw CancellationError() }
        isSavingProfile = true
        defer { isSavingProfile = false }

        let user = try await APIClient.shared.updateProfile(nickname: nickname, avatarURL: avatarURL)
        guard AccountSession.shared.isCurrent(accountScope) else { throw CancellationError() }

        currentUser = user
        AuthManager.shared.currentUser = user
        loadErrorMessage = nil
        return user
    }

    func changePassword(currentPassword: String, newPassword: String) async throws {
        guard AccountSession.shared.isCurrent(accountScope) else { throw CancellationError() }
        guard currentUser?.canChangePassword == true else {
            throw APIClient.APIError.serverError(L10n.t("此账号未设置密码，请使用原登录方式。", "This account has no password. Use its existing sign-in method."))
        }
        isChangingPassword = true
        defer { isChangingPassword = false }

        try await APIClient.shared.changePassword(currentPassword: currentPassword, newPassword: newPassword)
    }

    static func message(from error: Error) -> String {
        if let apiError = error as? APIClient.APIError {
            switch apiError {
            case .invalidURL:
                return L10n.t("服务器地址无效", "Invalid server URL")
            case .noData:
                return L10n.t("服务器没有返回可用数据", "The server returned no usable data")
            case .decodingError:
                return L10n.t("服务器数据解析失败", "Failed to parse server data")
            case .serverError(let message):
                return message
            case .unauthorized:
                return L10n.t("登录已过期，请重新登录", "Your session expired. Please sign in again")
            case .networkError(let error):
                return L10n.t("网络连接失败：\(error.localizedDescription)", "Network connection failed: \(error.localizedDescription)")
            }
        }

        return error.localizedDescription
    }
}

import Combine
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var currentUser: User?
    @Published var isLoading = false
    @Published var isSavingProfile = false
    @Published var isChangingPassword = false
    @Published var loadErrorMessage: String?

    init(previewUser: User? = nil) {
        self.currentUser = previewUser ?? AuthManager.shared.currentUser
    }

    func fetchProfile() async {
        guard !isLoading else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let user = try await APIClient.shared.fetchCurrentUserValue()
            currentUser = user
            AuthManager.shared.currentUser = user
            loadErrorMessage = nil
        } catch {
            loadErrorMessage = Self.message(from: error)
        }
    }

    func updateProfile(nickname: String, avatarURL: String) async throws -> User {
        isSavingProfile = true
        defer { isSavingProfile = false }

        let user = try await APIClient.shared.updateProfile(nickname: nickname, avatarURL: avatarURL)

        currentUser = user
        AuthManager.shared.currentUser = user
        loadErrorMessage = nil
        return user
    }

    func changePassword(currentPassword: String, newPassword: String) async throws {
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

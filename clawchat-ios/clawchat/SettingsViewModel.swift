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
                return "Invalid server URL"
            case .noData:
                return "The server returned no usable data"
            case .decodingError:
                return "Failed to parse server data"
            case .serverError(let message):
                return message
            case .unauthorized:
                return "Your session expired. Please sign in again"
            case .networkError(let error):
                return "Network connection failed: \(error.localizedDescription)"
            }
        }

        return error.localizedDescription
    }
}

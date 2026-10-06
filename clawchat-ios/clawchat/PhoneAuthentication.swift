import Foundation
import Combine

protocol PhoneAuthenticationAPI {
    var baseURL: URL { get }
    func fetchPhoneConfiguration() -> AnyPublisher<PhoneAuthConfiguration, Error>
    func requestPhoneCode(phone: String, captchaToken: String, purpose: String) -> AnyPublisher<PhoneCodeResponse, Error>
}

extension APIClient: PhoneAuthenticationAPI {}

struct PhoneAuthConfiguration: Codable {
    let enabled: Bool
    let captchaProvider: String
    enum CodingKeys: String, CodingKey {
        case enabled
        case captchaProvider = "captcha_provider"
    }
}

struct PhoneCaptchaChallenge: Identifiable {
    let id: UUID
    let url: URL

    static func url(baseURL: URL) -> URL? {
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && isLoopback(baseURL)),
              baseURL.user == nil, baseURL.password == nil else { return nil }
        return URL(string: "/api/v1/auth/phone/challenge", relativeTo: baseURL)?.absoluteURL
    }

    static func isLoopback(_ url: URL) -> Bool {
        ["localhost", "127.0.0.1", "[::1]", "::1"].contains(url.host?.lowercased() ?? "")
    }

    func acceptsMessage(from url: URL?, isMainFrame: Bool) -> Bool {
        guard isMainFrame, let url else { return false }
        return ServiceEndpointConfiguration.hasSameOrigin(self.url, url) && url.path == self.url.path
    }
}

enum PhoneCaptchaError: LocalizedError {
    case unavailable, failed, expired, contextChanged
    var errorDescription: String? {
        switch self {
        case .unavailable: return L10n.t("当前服务暂不支持手机号登录，请使用邮箱或用户名。", "Phone sign-in is unavailable. Use email or username.")
        case .failed: return L10n.t("安全验证未完成，请重试。", "Verification did not complete. Please try again.")
        case .expired: return L10n.t("安全验证已过期，请重新获取验证码。", "Verification expired. Request a new code.")
        case .contextChanged: return L10n.t("手机号或服务已变化，请重新获取验证码。", "The phone number or service changed. Request a new code.")
        }
    }
}

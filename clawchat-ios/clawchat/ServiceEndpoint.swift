import Foundation
import Combine

enum ServiceEndpointPreset: String, CaseIterable, Identifiable {
    case china
    case unitedStates
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .china:
            return L10n.t("中国区", "China")
        case .unitedStates:
            return L10n.t("美国区", "United States")
        case .custom:
            return L10n.t("自定义", "Custom")
        }
    }

    var subtitle: String {
        switch self {
        case .china:
            return ServiceEndpointConfiguration.chinaBaseURL.absoluteString
        case .unitedStates:
            return ServiceEndpointConfiguration.unitedStatesBaseURL.absoluteString
        case .custom:
            return L10n.t("测试或私有环境", "Test or private environment")
        }
    }
}

enum ServiceEndpointConfiguration {
    static let chinaBaseURL = URL(string: "https://test.iotdevices.site")!
    static let unitedStatesBaseURL = URL(string: "https://clawchat.changer.site")!

    static let selectedPresetKey = "serviceEndpoint.selectedPreset"
    static let customEndpointKey = "serviceEndpoint.customEndpoint"

    static var launchOverrideURL: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-openclawApiBaseURL"),
           arguments.indices.contains(arguments.index(after: index)) {
            let rawValue = arguments[arguments.index(after: index)].trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawValue.isEmpty, let url = URL(string: rawValue) {
                return url
            }
        }

        if let argument = arguments.first(where: { $0.hasPrefix("OPENCLAW_API_BASE_URL=") }) {
            let rawValue = String(argument.dropFirst("OPENCLAW_API_BASE_URL=".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawValue.isEmpty, let url = URL(string: rawValue) {
                return url
            }
        }

        let rawValue = ProcessInfo.processInfo.environment["OPENCLAW_API_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawValue, !rawValue.isEmpty, let url = URL(string: rawValue) {
            return url
        }

        return nil
    }

    static var isLaunchOverridden: Bool {
        launchOverrideURL != nil
    }

    static var selectedPreset: ServiceEndpointPreset {
        let rawValue = UserDefaults.standard.string(forKey: selectedPresetKey) ?? ServiceEndpointPreset.china.rawValue
        return ServiceEndpointPreset(rawValue: rawValue) ?? .china
    }

    static var customEndpointText: String {
        UserDefaults.standard.string(forKey: customEndpointKey) ?? ""
    }

    static var currentBaseURL: URL {
        if let launchOverrideURL {
            return launchOverrideURL
        }

        switch selectedPreset {
        case .china:
            return chinaBaseURL
        case .unitedStates:
            return unitedStatesBaseURL
        case .custom:
            return normalizedURL(from: customEndpointText) ?? chinaBaseURL
        }
    }

    static func endpointURL(for preset: ServiceEndpointPreset, customEndpointText: String) -> URL? {
        switch preset {
        case .china:
            return chinaBaseURL
        case .unitedStates:
            return unitedStatesBaseURL
        case .custom:
            return normalizedURL(from: customEndpointText)
        }
    }

    static func normalizedURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false
        else {
            return nil
        }

        components.scheme = scheme
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !components.path.isEmpty {
            components.path = "/\(components.path)"
        }
        components.query = nil
        components.fragment = nil

        return components.url
    }

    static func storageIdentifier(for url: URL) -> String {
        let rawValue = url.absoluteString.lowercased()
        let sanitized = rawValue.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(String(scalar))
            }
            return "-"
        }
        let compacted = String(sanitized)
            .split(separator: "-")
            .joined(separator: "-")
        return compacted.isEmpty ? "default" : compacted
    }
}

final class ServiceEndpointManager: ObservableObject {
    static let shared = ServiceEndpointManager()

    @Published private(set) var selectedPreset: ServiceEndpointPreset
    @Published private(set) var customEndpointText: String
    @Published private(set) var baseURL: URL

    var isLaunchOverridden: Bool {
        ServiceEndpointConfiguration.isLaunchOverridden
    }

    private init() {
        selectedPreset = ServiceEndpointConfiguration.selectedPreset
        customEndpointText = ServiceEndpointConfiguration.customEndpointText
        baseURL = ServiceEndpointConfiguration.currentBaseURL
    }

    func apply(preset: ServiceEndpointPreset, customEndpointText: String) throws -> Bool {
        guard !isLaunchOverridden else {
            throw EndpointError.launchOverrideActive
        }

        guard let newBaseURL = ServiceEndpointConfiguration.endpointURL(
            for: preset,
            customEndpointText: customEndpointText
        ) else {
            throw EndpointError.invalidURL
        }

        let normalizedCustomText: String
        if preset == .custom {
            normalizedCustomText = newBaseURL.absoluteString
        } else {
            normalizedCustomText = customEndpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let didChange = selectedPreset != preset
            || self.customEndpointText != normalizedCustomText
            || baseURL != newBaseURL

        UserDefaults.standard.set(preset.rawValue, forKey: ServiceEndpointConfiguration.selectedPresetKey)
        UserDefaults.standard.set(normalizedCustomText, forKey: ServiceEndpointConfiguration.customEndpointKey)

        selectedPreset = preset
        self.customEndpointText = normalizedCustomText
        baseURL = newBaseURL

        APIClient.rebuildShared()
        LocalMessageStore.shared.resetForCurrentServiceEndpoint()
        AuthManager.shared.logout()

        return didChange
    }

    enum EndpointError: LocalizedError {
        case invalidURL
        case launchOverrideActive

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return L10n.t("请输入有效的 http 或 https 地址。", "Enter a valid http or https endpoint.")
            case .launchOverrideActive:
                return L10n.t("当前启动参数已覆盖接口地址，无法在 App 内切换。", "A launch argument is overriding the endpoint, so it cannot be changed in the app.")
            }
        }
    }
}

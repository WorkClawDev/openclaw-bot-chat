import Foundation

enum AppLanguageMode: String, CaseIterable, Identifiable {
    case system
    case chinese
    case english

    static let storageKey = "settings.languageMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return L10n.t("跟随系统", "System")
        case .chinese:
            return L10n.t("中文", "Chinese")
        case .english:
            return "English"
        }
    }

    var subtitle: String {
        switch self {
        case .system:
            return L10n.t("使用 iOS 系统语言", "Uses the iOS language")
        case .chinese:
            return L10n.t("界面显示为中文", "Use Chinese for the interface")
        case .english:
            return L10n.t("界面显示为英文", "Use English for the interface")
        }
    }
}

enum L10n {
    private static let defaultEnglishMigrationKey = "settings.languageMode.defaultEnglishMigrated"

    private static var languageMode: AppLanguageMode {
        let defaults = UserDefaults.standard
        let rawValue = defaults.string(forKey: AppLanguageMode.storageKey)

        if !defaults.bool(forKey: defaultEnglishMigrationKey) {
            defaults.set(true, forKey: defaultEnglishMigrationKey)
            if rawValue == nil || rawValue == AppLanguageMode.system.rawValue {
                defaults.set(AppLanguageMode.english.rawValue, forKey: AppLanguageMode.storageKey)
                return .english
            }
        }

        return AppLanguageMode(rawValue: rawValue ?? AppLanguageMode.english.rawValue) ?? .english
    }

    static var isChinese: Bool {
        switch languageMode {
        case .system:
            return Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
        case .chinese:
            return true
        case .english:
            return false
        }
    }

    static func t(_ chinese: String, _ english: String) -> String {
        isChinese ? chinese : english
    }

    static var online: String { t("在线", "online") }
    static var offline: String { t("离线", "offline") }
    static var botsOnline: String { t("机器人在线", "bots online") }
    static var botsOffline: String { t("机器人离线", "bots offline") }
    static var chat: String { t("聊天", "chat") }
    static var botChat: String { t("机器人聊天", "bot chat") }
    static var groupChat: String { t("群聊", "group chat") }
    static var noMessagesYet: String { t("暂无消息", "No messages yet") }
    static var bot: String { t("机器人", "Bot") }
    static var user: String { t("用户", "User") }
}

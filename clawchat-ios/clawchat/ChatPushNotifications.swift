import SwiftUI
import UserNotifications
import Combine

enum ChatPushState: Equatable {
    case off, connecting, on, unavailable, denied, failed, revocationPending

    var label: String {
        switch self {
        case .off: return L10n.t("已关闭", "Off")
        case .connecting: return L10n.t("正在连接通知服务…", "Connecting notifications…")
        case .on: return L10n.t("已开启", "On")
        case .unavailable: return L10n.t("服务器尚未配置推送", "Push is not configured on this server")
        case .denied: return L10n.t("请在系统设置中允许通知", "Allow notifications in system Settings")
        case .failed: return L10n.t("连接失败，点按重试", "Connection failed. Tap to retry")
        case .revocationPending: return L10n.t("本机已关闭，等待服务器确认", "Off on this device; server confirmation pending")
        }
    }
}

struct ChatPushDestination: Identifiable {
    let id = UUID()
    let context: ChatContext
}

struct ChatPushSystem {
    var authorization: () async -> UNAuthorizationStatus
    var requestAuthorization: () async throws -> Bool
    var register: () -> Void
    var unregister: () -> Void
    var clearDelivered: () -> Void
    var environment: () -> String?

    static var live: Self {
        Self(authorization: { await UNUserNotificationCenter.current().notificationSettings().authorizationStatus },
             requestAuthorization: { try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) },
             register: { UIApplication.shared.registerForRemoteNotifications() },
             unregister: { UIApplication.shared.unregisterForRemoteNotifications() },
             clearDelivered: { UNUserNotificationCenter.current().removeAllDeliveredNotifications() },
             environment: {
                 switch provisioningEnvironment() ?? Bundle.main.object(forInfoDictionaryKey: "ClawChatAPNSEnvironment") as? String {
                 case "development": return "sandbox"
                 case "production": return "production"
                 default: return nil
                 }
             })
    }

    // Development/Ad Hoc provisioning can differ from the build configuration.
    // Prefer the profile embedded by signing; App Store builds use the configured
    // production fallback because their profile is removed during distribution.
    static func provisioningEnvironment() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return nil }
        return entitlements["aps-environment"] as? String ?? entitlements["com.apple.developer.aps-environment"] as? String
    }
}

@MainActor
final class ChatPushNotifications: ObservableObject {
    static let shared = ChatPushNotifications()
    static let enabledKey = "settings.botNotificationsEnabled"
    @Published private(set) var enabled: Bool
    @Published private(set) var state: ChatPushState = .off
    @Published var destination: ChatPushDestination?
    @Published var navigationError: String?
    private(set) var session: ChatPushSession?
    private(set) var installationID: UUID
    private let defaults: UserDefaults
    private let api: ChatPushAPIProtocol
    private let system: ChatPushSystem
    private var deviceToken: String?
    private var generation = 0
    private var needsSync = false
    private var shouldRequestPermission = false
    private var worker: Task<Void, Never>?
    private var registrationTimer: Task<Void, Never>?
    private var registrationRequested = false
    private var pendingRevocations: [ChatPushSession] = []
    private var pendingRoute: ChatPushRoute?
    private var navigationGeneration = 0
    private var navigationTask: Task<Void, Never>?
    private let tokenTimeout: Duration

    private struct Revocation: Codable, Equatable {
        let userID: UUID
        let endpoint: URL
        var matches: (ChatPushSession) -> Bool { { $0.userID == userID && $0.endpoint == endpoint } }
    }
    private let revocationsKey = "push.pendingRevocations"
    private var revocations: [Revocation] {
        get { (try? JSONDecoder().decode([Revocation].self, from: defaults.data(forKey: revocationsKey) ?? Data())) ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: revocationsKey) }
    }

    init(defaults: UserDefaults = .standard, api: ChatPushAPIProtocol? = nil, system: ChatPushSystem? = nil, tokenTimeout: Duration = .seconds(15)) {
        self.defaults = defaults
        self.api = api ?? ChatPushAPI()
        self.system = system ?? .live
        self.tokenTimeout = tokenTimeout
        let key = "push.installationID"
        installationID = defaults.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(installationID.uuidString, forKey: key)
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestResetPush") { defaults.set(false, forKey: Self.enabledKey) }
#endif
        enabled = defaults.bool(forKey: Self.enabledKey) && defaults.string(forKey: "push.enabledIdentity") != nil
    }

    func activate(_ newSession: ChatPushSession?) {
        if session?.identity != newSession?.identity {
            if let old = session { enqueueRevocation(old); setPreference(false); system.unregister(); system.clearDelivered() }
            generation += 1
            deviceToken = nil
            registrationRequested = false
            registrationTimer?.cancel()
            destination = nil
            navigationError = nil
            navigationGeneration += 1
            navigationTask?.cancel()
        }
        session = newSession
        if enabled, defaults.string(forKey: "push.enabledIdentity") != newSession?.identity { setPreference(false) }
        if let newSession, revocations.contains(where: { $0.matches(newSession) }) { enqueueRevocation(newSession) }
        scheduleSync()
        openPendingRoute()
    }

    func setEnabled(_ value: Bool) {
        guard session != nil else { return }
        generation += 1
        setPreference(value)
        shouldRequestPermission = value
        registrationRequested = false
        registrationTimer?.cancel()
        if !value {
            if let session { enqueueRevocation(session) }
            deviceToken = nil
            system.unregister()
            system.clearDelivered()
        }
        scheduleSync()
    }

    func logout() {
        if let session { enqueueRevocation(session) }
        generation += 1
        setPreference(false)
        shouldRequestPermission = false
        session = nil
        deviceToken = nil
        registrationRequested = false
        registrationTimer?.cancel()
        system.unregister()
        system.clearDelivered()
        destination = nil
        pendingRoute = nil
        navigationError = nil
        navigationGeneration += 1
        navigationTask?.cancel()
        scheduleSync()
    }

    func receivedDeviceToken(_ data: Data) {
        guard enabled, session != nil, registrationRequested else { return }
        registrationTimer?.cancel()
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        generation += 1
        scheduleSync()
    }

    func registrationFailed() {
        guard enabled, registrationRequested else { return }
        registrationTimer?.cancel()
        registrationRequested = false
        state = .failed
    }

    func shouldPresent(_ userInfo: [AnyHashable: Any], activeConversationID: String?) -> Bool {
        ChatPushRoute(userInfo: userInfo)?.shouldPresent(currentUserID: session?.userID, enabled: enabled, activeConversationID: activeConversationID) == true
    }

    func receivedTap(_ userInfo: [AnyHashable: Any]) {
        guard let route = ChatPushRoute(userInfo: userInfo) else { return }
        pendingRoute = route
        openPendingRoute()
    }

    private func openPendingRoute() {
        guard let route = pendingRoute, let session else { return }
        pendingRoute = nil
        guard route.userID == session.userID else { return }
        navigationGeneration += 1
        let ticket = navigationGeneration
        navigationTask?.cancel()
        navigationError = nil
        navigationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let context = try await api.resolve(route: route, session: session)
                guard !Task.isCancelled, ticket == navigationGeneration, self.session?.identity == session.identity else { return }
                destination = ChatPushDestination(context: context)
            } catch {
                guard !Task.isCancelled, ticket == navigationGeneration, self.session?.identity == session.identity else { return }
                navigationError = L10n.t("暂时无法打开这段聊天。请确认网络连接及聊天权限后重试。", "This chat could not be opened. Check your connection and access, then try again.")
            }
        }
    }

    private func setPreference(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: Self.enabledKey)
        if value { defaults.set(session?.identity, forKey: "push.enabledIdentity") }
        else { defaults.removeObject(forKey: "push.enabledIdentity") }
    }

    private func enqueueRevocation(_ session: ChatPushSession) {
        pendingRevocations.removeAll { $0.identity == session.identity }
        pendingRevocations.append(session)
        let item = Revocation(userID: session.userID, endpoint: session.endpoint)
        if !revocations.contains(item) { revocations.append(item) }
        // Persist routing only. Never retain a logged-out account's JWT on disk.
    }

    private func scheduleSync() {
        needsSync = true
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while needsSync {
                needsSync = false
                await synchronize()
            }
            worker = nil
        }
    }

    private func synchronize() async {
        while !pendingRevocations.isEmpty {
            let old = pendingRevocations.removeFirst()
            do {
                try await api.revoke(session: old, installationID: installationID)
                revocations.removeAll { $0.matches(old) }
            } catch { /* Retry with fresh credentials on the next matching login/activation. */ }
        }
        guard enabled, let session else {
            if !revocations.isEmpty { state = .revocationPending; return }
            // Dismissing the permission alert reactivates the app and queues a
            // second sync. Preserve the actionable denial reason on that sync,
            // and refresh it when the user returns from system Settings.
            guard let identity = self.session?.identity else { state = .off; return }
            let ticket = generation
            let authorization = await system.authorization()
            guard generation == ticket, !enabled, self.session?.identity == identity else { return }
            state = authorization == .denied ? .denied : .off
            return
        }
        let ticket = generation
        let matches = { self.generation == ticket && self.enabled && self.session?.identity == session.identity }
        state = .connecting
        do {
            guard try await api.available(session: session) else {
                if matches() { state = .unavailable }
                return
            }
            guard matches() else { return }
            var authorization = await system.authorization()
            guard matches() else { return }
            if authorization == .notDetermined, shouldRequestPermission {
                shouldRequestPermission = false
                _ = try await system.requestAuthorization()
                authorization = await system.authorization()
                guard matches() else { return }
            }
            guard authorization == .authorized || authorization == .provisional || authorization == .ephemeral else {
                setPreference(false)
                enqueueRevocation(session)
                system.unregister()
                state = .denied
                // Do not schedule an endless loop or hide the permission reason.
                if let old = pendingRevocations.popLast() {
                    do { try await api.revoke(session: old, installationID: installationID); revocations.removeAll { $0.matches(old) } } catch {}
                }
                return
            }
            guard let environment = system.environment() else { state = .failed; return }
            guard let deviceToken else {
                if !registrationRequested {
                    registrationRequested = true
                    system.register()
                    registrationTimer = Task { [weak self] in
                        guard let self else { return }
                        do { try await Task.sleep(for: tokenTimeout) } catch { return }
                        guard generation == ticket, enabled, deviceToken == nil else { return }
                        registrationRequested = false
                        state = .failed
                    }
                }
                return
            }
            let language = defaults.string(forKey: AppLanguageMode.storageKey) == AppLanguageMode.chinese.rawValue ? "zh" : "en"
            try await api.register(session: session, installationID: installationID, token: deviceToken, environment: environment, language: language)
            guard matches(), self.deviceToken == deviceToken else { return }
            state = .on
        } catch {
            guard matches() else { return }
            state = (error as? ChatPushError) == .unavailable ? .unavailable : .failed
        }
    }

    // Test synchronization observes actual work, rather than arbitrary sleeps.
    func waitForIdle() async { await worker?.value }
    func waitForNavigation() async { await navigationTask?.value }
}

final class ChatPushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        ChatPushNotifications.shared.receivedDeviceToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        ChatPushNotifications.shared.registrationFailed()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let info = notification.request.content.userInfo
        Task { @MainActor in
            let show = ChatPushNotifications.shared.shouldPresent(info, activeConversationID: RealtimeService.shared.visibleConversationID)
            completionHandler(show ? [.banner, .list, .sound] : [])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        Task { @MainActor in
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier { ChatPushNotifications.shared.receivedTap(info) }
            completionHandler()
        }
    }
}

private struct NotificationChatCloseKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
    var closeNotificationChat: (() -> Void)? {
        get { self[NotificationChatCloseKey.self] }
        set { self[NotificationChatCloseKey.self] = newValue }
    }
}

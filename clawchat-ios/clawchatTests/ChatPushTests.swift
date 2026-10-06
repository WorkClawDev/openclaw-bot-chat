import Foundation
import Testing
import UserNotifications
@testable import clawchat

@MainActor
struct ChatPushTests {
    @Test func signedBuildHasExplicitAPNsEnvironmentFallback() {
#if DEBUG
        #expect(ChatPushSystem.live.environment() == "sandbox")
#else
        #expect(ChatPushSystem.live.environment() == "production")
#endif
    }
    @Test func permissionAloneNeverReportsRegistered() async {
        let h = Harness()
        h.system.authorization = .notDetermined
        h.manager.activate(h.session)
        h.manager.setEnabled(true)
        await h.manager.waitForIdle()
        #expect(h.system.requests == 1)
        #expect(h.system.registrations == 1)
        #expect(h.manager.state == .connecting)
        #expect(h.api.registeredTokens.isEmpty)
        h.manager.receivedDeviceToken(Data([0xab, 0xcd]))
        await h.manager.waitForIdle()
        #expect(h.api.registeredTokens == ["abcd"])
        #expect(h.manager.state == .on)
        h.manager.logout()
        await h.manager.waitForIdle()
    }

    @Test func unavailableServerDoesNotRequestPermissionAndCanRetry() async {
        let h = Harness()
        h.api.isAvailable = false
        h.manager.activate(h.session)
        h.manager.setEnabled(true)
        await h.manager.waitForIdle()
        #expect(h.manager.state == .unavailable)
        #expect(h.system.requests == 0 && h.system.registrations == 0)
        h.api.isAvailable = true
        h.manager.setEnabled(true)
        await h.manager.waitForIdle()
        h.manager.receivedDeviceToken(Data([1, 2]))
        await h.manager.waitForIdle()
        #expect(h.manager.state == .on)
        h.manager.logout()
        await h.manager.waitForIdle()
    }

    @Test func deniedPermissionNeverRegistersAndClearsIntent() async {
        let h = Harness()
        h.system.authorization = .denied
        h.manager.activate(h.session)
        h.manager.setEnabled(true)
        await h.manager.waitForIdle()
        #expect(h.manager.state == .denied)
        #expect(!h.manager.enabled)
        #expect(h.system.registrations == 0 && h.api.registeredTokens.isEmpty)
        #expect(h.api.revokedUsers == [h.session.userID])
        // Native permission dialogs deactivate/reactivate the app. A follow-up
        // activation must retain the reason and the route to system Settings.
        h.manager.activate(h.session)
        await h.manager.waitForIdle()
        #expect(h.manager.state == .denied && !h.manager.enabled)
        h.system.authorization = .authorized
        h.manager.activate(h.session)
        await h.manager.waitForIdle()
        #expect(h.manager.state == .off && !h.manager.enabled)
        #expect(h.api.registeredTokens.isEmpty)
    }

    @Test func disablingDuringRegistrationWaitsThenRevokes() async {
        let h = Harness()
        h.api.holdRegistration = true
        await h.startTokenRequest()
        h.manager.receivedDeviceToken(Data([1, 2]))
        guard await h.api.waitForHeldRegistration() else { Issue.record("registration did not reach the API"); return }
        #expect(h.manager.state == .connecting)
        h.manager.setEnabled(false)
        #expect(!h.manager.enabled)
        #expect(h.system.unregistrations == 1)
        h.api.releaseRegistration()
        await h.manager.waitForIdle()
        #expect(h.api.events == ["register", "registered", "revoke"])
        #expect(h.manager.state == .off)
    }

    @Test func logoutRejectsLateTokensAndRegistrationAcknowledgement() async {
        let h = Harness()
        h.api.holdRegistration = true
        await h.startTokenRequest()
        h.manager.receivedDeviceToken(Data([0xab]))
        guard await h.api.waitForHeldRegistration() else { Issue.record("registration did not reach the API"); return }
        h.manager.logout()
        h.manager.receivedDeviceToken(Data([0xcd]))
        h.api.releaseRegistration()
        await h.manager.waitForIdle()
        #expect(h.manager.session == nil && !h.manager.enabled)
        #expect(h.api.registeredTokens == ["ab"])
        #expect(h.api.revokedUsers == [h.session.userID])
        #expect(h.manager.state == .off)
    }

    @Test func tokenRotationCannotLeaveOldRegistrationAsCurrent() async {
        let h = Harness()
        h.api.holdRegistration = true
        await h.startTokenRequest()
        h.manager.receivedDeviceToken(Data([1]))
        guard await h.api.waitForHeldRegistration() else { Issue.record("registration did not reach the API"); return }
        h.manager.receivedDeviceToken(Data([2]))
        h.api.releaseRegistration()
        await h.manager.waitForIdle()
        #expect(h.api.registeredTokens == ["01", "02"])
        #expect(h.manager.state == .on)
        h.manager.logout()
        await h.manager.waitForIdle()
    }

    @Test func failedRevocationIsRetriedWithoutPersistingJWT() async {
        let h = Harness()
        await h.startTokenRequest()
        h.manager.receivedDeviceToken(Data([1]))
        await h.manager.waitForIdle()
        h.api.failRevoke = true
        h.manager.setEnabled(false)
        await h.manager.waitForIdle()
        #expect(h.manager.state == .revocationPending && !h.manager.enabled)
        let bytes = h.defaults.data(forKey: "push.pendingRevocations") ?? Data()
        #expect(!String(decoding: bytes, as: UTF8.self).contains(h.session.accessToken))
        h.api.failRevoke = false
        let fresh = ChatPushSession(userID: h.session.userID, accessToken: "fresh-test-token", endpoint: h.session.endpoint)
        h.manager.activate(fresh)
        await h.manager.waitForIdle()
        #expect(h.api.revocationTokens.last == "fresh-test-token")
        #expect(h.manager.state == .off)
    }

    @Test func registrationFailureCanRetryWithoutFakeSuccess() async {
        let h = Harness()
        h.api.failRegister = true
        await h.startTokenRequest()
        h.manager.receivedDeviceToken(Data([4]))
        await h.manager.waitForIdle()
        #expect(h.manager.state == .failed)
        h.api.failRegister = false
        h.manager.setEnabled(true)
        await h.manager.waitForIdle()
        #expect(h.manager.state == .on)
        h.manager.logout()
        await h.manager.waitForIdle()
    }

    @Test func nativeRegistrationErrorAndTimeoutAreVisible() async throws {
        let h = Harness(timeout: .milliseconds(30))
        await h.startTokenRequest()
        h.manager.registrationFailed()
        #expect(h.manager.state == .failed)
        h.manager.setEnabled(true)
        await h.manager.waitForIdle()
        try await Task.sleep(for: .milliseconds(80))
        #expect(h.manager.state == .failed)
        h.manager.logout()
        await h.manager.waitForIdle()
    }

    @Test func intentDoesNotTransferToDifferentAccountOrServer() async {
        let h = Harness()
        await h.startTokenRequest()
        h.manager.receivedDeviceToken(Data([1]))
        await h.manager.waitForIdle()
        let other = ChatPushSession(userID: UUID(), accessToken: "other", endpoint: h.session.endpoint)
        h.manager.activate(other)
        await h.manager.waitForIdle()
        #expect(!h.manager.enabled && h.manager.state == .off)
        #expect(h.api.revokedUsers == [h.session.userID])
        #expect(h.system.clears == 1)
    }

    @Test func coldNotificationWaitsForMatchingAuthenticatedAccount() async throws {
        let h = Harness()
        h.manager.receivedTap(h.payload())
        #expect(h.api.resolutions == 0 && h.manager.destination == nil)
        h.manager.activate(h.session)
        await h.manager.waitForNavigation()
        #expect(h.api.resolutions == 1)
        let expected = try #require(ChatPushRoute(userInfo: h.payload())).conversationID
        #expect(h.manager.destination?.context.id == expected)
        h.manager.logout()
        await h.manager.waitForIdle()
    }

    @Test func accountChangeRejectsLateNavigationAndForeignNotification() async {
        let h = Harness()
        h.manager.activate(h.session)
        h.api.holdResolve = true
        h.manager.receivedTap(h.payload())
        guard await h.api.waitForHeldResolution() else { Issue.record("route did not reach the resolver"); return }
        let other = ChatPushSession(userID: UUID(), accessToken: "other", endpoint: h.session.endpoint)
        h.manager.activate(other)
        h.api.releaseResolution()
        await Task.yield()
        h.manager.receivedTap(h.payload())
        await h.manager.waitForNavigation()
        #expect(h.manager.destination == nil && h.api.resolutions == 1)
        h.manager.logout()
        await h.manager.waitForIdle()
    }

    @Test func revokedConversationShowsErrorWithoutNavigation() async {
        let h = Harness()
        h.api.failResolve = true
        h.manager.activate(h.session)
        h.manager.receivedTap(h.payload())
        await h.manager.waitForNavigation()
        #expect(h.manager.destination == nil)
        #expect(h.manager.navigationError != nil)
        h.manager.activate(ChatPushSession(userID: UUID(), accessToken: "other", endpoint: h.session.endpoint))
        #expect(h.manager.navigationError == nil, "An account change must dismiss the previous account's navigation error")
        h.manager.logout()
        await h.manager.waitForIdle()
    }

    @Test func foregroundRoutingSuppressesSameChatOtherAccountAndMalformedPayloads() throws {
        let h = Harness()
        let route = try #require(ChatPushRoute(userInfo: h.payload()))
        #expect(route.shouldPresent(currentUserID: h.session.userID, enabled: true, activeConversationID: nil))
        #expect(!route.shouldPresent(currentUserID: h.session.userID, enabled: true, activeConversationID: route.conversationID.uppercased()))
        #expect(!route.shouldPresent(currentUserID: UUID(), enabled: true, activeConversationID: nil))
        #expect(!route.shouldPresent(currentUserID: h.session.userID, enabled: false, activeConversationID: nil))
        var bad = h.payload()
        bad["conversation_id"] = "https://example.com/chat"
        #expect(ChatPushRoute(userInfo: bad) == nil)
        bad = h.payload(); bad["user_id"] = UUID().uuidString
        #expect(ChatPushRoute(userInfo: bad) == nil)
        bad = h.payload(); bad["conversation_id"] = "chat/group/\(UUID().uuidString)"
        #expect(ChatPushRoute(userInfo: bad)?.groupID != nil)
    }
}

@MainActor
private final class PushSystemFixture {
    var authorization: UNAuthorizationStatus = .authorized
    var requests = 0
    var registrations = 0
    var unregistrations = 0
    var clears = 0
    var system: ChatPushSystem {
        ChatPushSystem(authorization: { self.authorization }, requestAuthorization: { self.requests += 1; self.authorization = .authorized; return true }, register: { self.registrations += 1 }, unregister: { self.unregistrations += 1 }, clearDelivered: { self.clears += 1 }, environment: { "sandbox" })
    }
}

@MainActor
private final class PushAPIFixture: ChatPushAPIProtocol {
    var isAvailable = true
    var failRegister = false
    var failRevoke = false
    var failResolve = false
    var registeredTokens: [String] = []
    var revokedUsers: [UUID] = []
    var revocationTokens: [String] = []
    var events: [String] = []
    var resolutions = 0
    var holdRegistration = false
    var holdResolve = false
    var registrationGate: CheckedContinuation<Void, Never>?
    var resolutionGate: CheckedContinuation<Void, Never>?
    func available(session: ChatPushSession) async throws -> Bool { isAvailable }
    func register(session: ChatPushSession, installationID: UUID, token: String, environment: String, language: String) async throws {
        events.append("register")
        registeredTokens.append(token)
        if holdRegistration { await withCheckedContinuation { registrationGate = $0 } }
        if failRegister { throw ChatPushError.rejected }
        events.append("registered")
    }
    func revoke(session: ChatPushSession, installationID: UUID) async throws {
        events.append("revoke")
        revokedUsers.append(session.userID)
        revocationTokens.append(session.accessToken)
        if failRevoke { throw ChatPushError.rejected }
    }
    func resolve(route: ChatPushRoute, session: ChatPushSession) async throws -> ChatContext {
        resolutions += 1
        if holdResolve { await withCheckedContinuation { resolutionGate = $0 } }
        if failResolve { throw ChatPushError.rejected }
        return ChatContext(id: route.conversationID, title: "Verified bot", subtitle: "", isGroup: false)
    }
    func releaseRegistration() { holdRegistration = false; registrationGate?.resume(); registrationGate = nil }
    func releaseResolution() { holdResolve = false; resolutionGate?.resume(); resolutionGate = nil }
    func waitForHeldRegistration() async -> Bool {
        for _ in 0..<500 { if registrationGate != nil { return true }; try? await Task.sleep(for: .milliseconds(10)) }; return false
    }
    func waitForHeldResolution() async -> Bool {
        for _ in 0..<500 { if resolutionGate != nil { return true }; try? await Task.sleep(for: .milliseconds(10)) }; return false
    }
}

@MainActor
private final class Harness {
    let defaults: UserDefaults
    let system = PushSystemFixture()
    let api = PushAPIFixture()
    let manager: ChatPushNotifications
    let session = ChatPushSession(userID: UUID(), accessToken: "test-access-token-never-persist", endpoint: URL(string: "https://fixture.example")!)
    let botID = UUID()
    let messageID = UUID()
    init(timeout: Duration = .seconds(15)) {
        defaults = UserDefaults(suiteName: "push-tests-\(UUID().uuidString)")!
        manager = ChatPushNotifications(defaults: defaults, api: api, system: system.system, tokenTimeout: timeout)
    }
    func startTokenRequest() async {
        manager.activate(session)
        manager.setEnabled(true)
        await manager.waitForIdle()
    }
    func payload() -> [AnyHashable: Any] {
        ["kind":"chat_message", "user_id":session.userID.uuidString, "conversation_id":"chat/dm/user/\(session.userID.uuidString)/bot/\(botID.uuidString)", "message_id":messageID.uuidString]
    }
}

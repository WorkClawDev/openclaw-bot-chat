import Foundation
import Testing
import CocoaMQTT
@testable import clawchat

@MainActor
struct RealtimeSessionTests {
    @Test func logoutClearsLastMessageSummaries() {
        let service = RealtimeService()
        service.lastMessagesByConversation["private"] = AccountIsolationTests.message("old-account")
        service.stop()
        #expect(service.lastMessagesByConversation.isEmpty)
    }
    @Test func disappearingChatCannotClearTheNewVisibleChat() {
        let service = RealtimeService()
        let previous = UUID(), current = UUID()
        service.setActiveConversation("visibility-fixture", owner: previous)
        service.setActiveConversation("visibility-fixture", owner: current)
        service.clearActiveConversation(owner: previous)
        #expect(service.visibleConversationID == "visibility-fixture")
        service.clearActiveConversation(owner: current)
        #expect(service.visibleConversationID == nil)
        service.stop()
    }
    @Test func readsBrokerCredentialExpiryAndSupportsOlderServers() throws {
        let decoder = JSONDecoder()
        let current = try decoder.decode(BrokerInfo.self, from: Data(#"{"ws_url":"ws://localhost/mqtt","expires_at":1800000300}"#.utf8))
        #expect(current.expiresAt == 1_800_000_300)
        let legacy = try decoder.decode(BrokerInfo.self, from: Data(#"{"ws_url":"ws://localhost/mqtt"}"#.utf8))
        #expect(legacy.expiresAt == nil)
    }

    @Test func refreshesBeforeExpiryWithoutTightRetryLoops() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(BrokerSessionPolicy.renewalDelay(expiresAt: 1_800_000_300, now: now) == 270)
        #expect(BrokerSessionPolicy.renewalDelay(expiresAt: 1_799_999_999, now: now) == 3)
        #expect(BrokerSessionPolicy.renewalDelay(expiresAt: nil, now: now) == nil)
    }

    @Test func oldConnectionCannotResurrectOrDisconnectCurrentSession() {
        let service = RealtimeService()
        let obsolete = CocoaMQTT(clientID: "obsolete-test-session", host: "localhost")
        service.mqtt(obsolete, didConnectAck: .accept)
        #expect(service.connectionState == .idle)
        service.connectionState = .connected
        service.mqtt(obsolete, didStateChangeTo: .disconnected)
        service.mqttDidDisconnect(obsolete, withError: nil)
        #expect(service.connectionState == .connected)
        service.stop()
    }
}

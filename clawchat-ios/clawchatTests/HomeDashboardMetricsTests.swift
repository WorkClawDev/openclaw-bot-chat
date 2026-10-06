import Foundation
import Testing
@testable import clawchat

struct HomeDashboardMetricsTests {
    @Test func aggregatesDashboardCounts() throws {
        let metrics = HomeDashboardMetrics(
            bots: [
                makeBot(status: "online"),
                makeBot(status: "offline"),
                makeBot(status: nil)
            ],
            groups: [
                makeGroup(isActive: true),
                makeGroup(isActive: false),
                makeGroup(isActive: nil)
            ],
            conversations: [
                makeConversation(unreadCount: 2),
                makeConversation(unreadCount: nil),
                makeConversation(unreadCount: -3)
            ]
        )

        #expect(metrics.totalBots == 3)
        #expect(metrics.enabledBots == 1)
        #expect(metrics.totalGroups == 3)
        #expect(metrics.activeGroups == 1)
        #expect(metrics.totalConversations == 3)
        #expect(metrics.unreadMessages == 2)
    }

    @Test func legacyBotStatusIsActivationNotRuntimePresence() throws {
        for (value, expected) in [("online", BotActivation.enabled), ("offline", .disabled), ("enabled", .enabled), ("disabled", .disabled), ("error", .unknown)] {
            let data = Data("{\"id\":\"00000000-0000-4000-8000-000000000001\",\"name\":\"Unused bot\",\"status\":\"\(value)\"}".utf8)
            let bot = try JSONDecoder().decode(Bot.self, from: data)
            #expect(bot.activation == expected)
        }
        #expect(makeBot(status: nil).activation == .unknown)
    }

    private func makeBot(status: String?) -> Bot {
        Bot(
            id: UUID(),
            ownerId: UUID(),
            name: "Bot",
            description: nil,
            avatar: nil,
            avatarUrl: nil,
            botType: nil,
            status: status,
            mqttTopic: nil,
            createdAt: nil,
            updatedAt: nil
        )
    }

    private func makeGroup(isActive: Bool?) -> ChatGroup {
        ChatGroup(
            id: UUID(),
            name: "Group",
            description: nil,
            avatar: nil,
            avatarUrl: nil,
            ownerId: UUID(),
            memberCount: nil,
            isActive: isActive,
            mqttTopic: nil,
            createdAt: nil,
            updatedAt: nil
        )
    }

    private func makeConversation(unreadCount: Int?) -> Conversation {
        Conversation(
            id: UUID().uuidString,
            type: "group",
            name: "Conversation",
            avatar: nil,
            targetId: nil,
            lastMessage: nil,
            unreadCount: unreadCount
        )
    }
}

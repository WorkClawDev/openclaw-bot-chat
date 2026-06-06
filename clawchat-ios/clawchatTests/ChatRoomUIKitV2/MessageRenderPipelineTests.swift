import Foundation
import Testing
@testable import clawchat

struct MessageRenderPipelineTests {
    @Test func rendersOneThousandTextMessagesWithStableGeometry() async throws {
        let coordinator = MessageRenderCoordinator(currentUserID: ChatRoomV2MockMessageFactory.currentUserID)
        let rawMessages = ChatRoomV2MockMessageFactory.benchmarkMessages(count: 1_000)

        let firstRender = await coordinator.renderPage(rawMessages, width: 390)
        let secondRender = await coordinator.renderPage(rawMessages, width: 390)

        #expect(firstRender.count == 1_000)
        #expect(firstRender.map(\.id) == secondRender.map(\.id))
        #expect(firstRender.map { $0.layout.rowHeight } == secondRender.map { $0.layout.rowHeight })
        #expect(firstRender.allSatisfy { $0.layout.rowHeight > 0 })
        #expect(firstRender.allSatisfy { $0.firstRichTextBlock?.measuredHeight ?? 0 > 0 })
    }

    @Test func blockIDsAreDerivedFromMessageAndContent() async throws {
        let coordinator = MessageRenderCoordinator(currentUserID: ChatRoomV2MockMessageFactory.currentUserID)
        let raw = RawMessage(
            id: "m-1",
            senderID: "u-1",
            conversationID: "c-1",
            content: .text("Stable text"),
            createdAt: Date(timeIntervalSince1970: 1),
            status: .complete,
            contentVersion: "v1"
        )

        let first = await coordinator.render(raw, width: 390)
        let second = await coordinator.render(raw, width: 390)

        #expect(first.blocks.map(\.id) == second.blocks.map(\.id))
    }
}

import Foundation
import Testing
@testable import clawchat

@MainActor
struct AnchorRestorationTests {
    @Test func prependingHistoryKeepsAnchorMessageAddressable() async throws {
        let coordinator = MessageRenderCoordinator(currentUserID: ChatRoomV2MockMessageFactory.currentUserID)
        let store = ChatMessageStore()
        let initial = await coordinator.renderPage(ChatRoomV2MockMessageFactory.initialMessages(count: 60), width: 390)
        store.initialLoad(initial)

        let anchorID = store.messages[10].id
        let page = await coordinator.renderPage(ChatRoomV2MockMessageFactory.historyPage(pageIndex: 0), width: 390)
        store.prependHistory(page)

        #expect(store.messages.first?.id == "mock-0970")
        #expect(store.messages.firstIndex(where: { $0.id == anchorID }) == 40)
    }

    @Test func twentyConsecutivePrependsKeepStableRows() async throws {
        let coordinator = MessageRenderCoordinator(currentUserID: ChatRoomV2MockMessageFactory.currentUserID)
        let store = ChatMessageStore()
        let initial = await coordinator.renderPage(ChatRoomV2MockMessageFactory.initialMessages(count: 60), width: 390)
        store.initialLoad(initial)

        let anchorID = store.messages[20].id

        for pageIndex in 0..<20 {
            let rawPage = ChatRoomV2MockMessageFactory.historyPage(pageIndex: pageIndex)
            let page = await coordinator.renderPage(rawPage, width: 390)
            store.prependHistory(page)
        }

        #expect(store.messages.count == 660)
        #expect(store.messages.firstIndex(where: { $0.id == anchorID }) == 620)
        #expect(store.messages.allSatisfy { $0.layout.rowHeight > 0 })
    }
}

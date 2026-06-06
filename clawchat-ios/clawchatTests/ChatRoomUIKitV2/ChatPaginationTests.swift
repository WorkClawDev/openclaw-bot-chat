import Foundation
import Testing
@testable import clawchat

@MainActor
struct ChatPaginationTests {
    @Test func preloadsAtTwoViewportHeights() async throws {
        let controller = ChatPaginationController(pageSize: 30) { _, pageSize in
            ChatRoomV2MockMessageFactory.historyPage(pageIndex: 0, pageSize: pageSize)
        }

        #expect(controller.shouldPreload(contentOffsetY: 799, viewportHeight: 400))
        #expect(!controller.shouldPreload(contentOffsetY: 800, viewportHeight: 400))
    }

    @Test func loadsThirtyMessagePagesInOrder() async throws {
        let controller = ChatPaginationController(pageSize: 30) { pageIndex, pageSize in
            ChatRoomV2MockMessageFactory.historyPage(pageIndex: pageIndex, pageSize: pageSize)
        }

        let first = await controller.loadPreviousPageIfNeeded(contentOffsetY: 0, viewportHeight: 400)
        let second = await controller.loadPreviousPageIfNeeded(contentOffsetY: 0, viewportHeight: 400)

        #expect(first.count == 30)
        #expect(second.count == 30)
        #expect(first.first?.id == "mock-0970")
        #expect(second.first?.id == "mock-0940")
        #expect(controller.nextPageIndex == 2)
    }
}

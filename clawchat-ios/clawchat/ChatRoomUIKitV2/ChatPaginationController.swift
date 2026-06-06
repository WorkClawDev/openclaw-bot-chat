import Foundation
import UIKit

struct VisibleMessageAnchor: Equatable {
    let messageID: String
    let offsetFromViewportTop: CGFloat
}

@MainActor
final class ChatPaginationController {
    typealias HistoryProvider = (_ pageIndex: Int, _ pageSize: Int) async -> [RawMessage]

    private let pageSize: Int
    private let historyProvider: HistoryProvider
    private(set) var nextPageIndex = 0
    private(set) var isLoading = false
    private(set) var hasMoreHistory = true
    var preloadViewportMultiplier: CGFloat = 2

    init(pageSize: Int = 30, historyProvider: @escaping HistoryProvider) {
        self.pageSize = pageSize
        self.historyProvider = historyProvider
    }

    func shouldPreload(contentOffsetY: CGFloat, viewportHeight: CGFloat) -> Bool {
        guard hasMoreHistory, !isLoading else { return false }
        return contentOffsetY < viewportHeight * preloadViewportMultiplier
    }

    func loadPreviousPageIfNeeded(contentOffsetY: CGFloat, viewportHeight: CGFloat) async -> [RawMessage] {
        guard shouldPreload(contentOffsetY: contentOffsetY, viewportHeight: viewportHeight) else {
            return []
        }

        isLoading = true
        defer { isLoading = false }

        let page = await historyProvider(nextPageIndex, pageSize)
        if page.isEmpty {
            hasMoreHistory = false
        } else {
            nextPageIndex += 1
            if page.count < pageSize {
                hasMoreHistory = false
            }
        }

        return page
    }
}

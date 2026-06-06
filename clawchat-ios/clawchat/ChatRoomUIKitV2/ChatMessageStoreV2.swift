import Foundation
import UIKit

@MainActor
final class ChatMessageStoreV2 {
    private(set) var messages: [RenderedMessageV2] = []

    var count: Int {
        messages.count
    }

    var earliestSequence: Int? {
        messages.first?.sequence
    }

    func initialLoad(_ messages: [RenderedMessageV2]) {
        self.messages = Self.sortedUnique(messages)
    }

    func prependHistory(_ page: [RenderedMessageV2]) {
        guard !page.isEmpty else { return }
        messages = Self.sortedUnique(page + messages)
    }

    func append(_ message: RenderedMessageV2) {
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        messages.append(message)
    }

    func replaceAll(_ messages: [RenderedMessageV2]) {
        self.messages = Self.sortedUnique(messages)
    }

    func message(at indexPath: IndexPath) -> RenderedMessageV2? {
        guard indexPath.section == 0, messages.indices.contains(indexPath.item) else {
            return nil
        }
        return messages[indexPath.item]
    }

    func firstIndex(messageID: String) -> Int? {
        messages.firstIndex { $0.id == messageID }
    }

    private static func sortedUnique(_ messages: [RenderedMessageV2]) -> [RenderedMessageV2] {
        var seen = Set<String>()
        return messages
            .sorted { lhs, rhs in
                if lhs.sequence == rhs.sequence {
                    return lhs.id < rhs.id
                }
                return lhs.sequence < rhs.sequence
            }
            .filter { seen.insert($0.id).inserted }
    }
}

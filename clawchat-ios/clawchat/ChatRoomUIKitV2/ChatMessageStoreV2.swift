import Foundation
import UIKit

@MainActor
final class ChatMessageStoreV2 {
    private(set) var messages: [RenderedMessageV2] = []
    private(set) var messageIDs: [String] = []
    private var messageIDSet = Set<String>()

    var count: Int {
        messages.count
    }

    var earliestSequence: Int? {
        messages.first?.sequence
    }

    func initialLoad(_ messages: [RenderedMessageV2]) {
        assign(Self.normalized(messages))
    }

    func prependHistory(_ page: [RenderedMessageV2]) {
        guard !page.isEmpty else { return }
        assign(Self.normalized(page + messages))
    }

    func append(_ message: RenderedMessageV2) {
        guard messageIDSet.insert(message.id).inserted else { return }
        messages.append(message)
        messageIDs.append(message.id)
    }

    func replaceAll(_ messages: [RenderedMessageV2]) {
        assign(Self.normalized(messages))
    }

    func message(at indexPath: IndexPath) -> RenderedMessageV2? {
        guard indexPath.section == 0, messages.indices.contains(indexPath.item) else {
            return nil
        }
        return messages[indexPath.item]
    }

    func firstIndex(messageID: String) -> Int? {
        messageIDs.firstIndex(of: messageID)
    }

    static func normalized(_ messages: [RenderedMessageV2]) -> [RenderedMessageV2] {
        if isStrictlySortedAndUnique(messages) {
            return messages
        }

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

    private static func isStrictlySortedAndUnique(_ messages: [RenderedMessageV2]) -> Bool {
        guard !messages.isEmpty else { return true }
        var seen = Set<String>()
        seen.reserveCapacity(messages.count)

        for (index, message) in messages.enumerated() {
            guard seen.insert(message.id).inserted else { return false }
            guard index > 0 else { continue }

            let previous = messages[index - 1]
            if previous.sequence > message.sequence {
                return false
            }
            if previous.sequence == message.sequence, previous.id >= message.id {
                return false
            }
        }
        return true
    }

    private func assign(_ messages: [RenderedMessageV2]) {
        self.messages = messages
        messageIDs = messages.map(\.id)
        messageIDSet = Set(messageIDs)
    }
}

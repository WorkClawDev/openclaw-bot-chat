import Foundation

@MainActor
final class ChatMessageStore {
    private(set) var messages: [RenderedMessage] = []

    func initialLoad(_ messages: [RenderedMessage]) {
        self.messages = Self.sortedUnique(messages)
        ChatDiagnostics.assertUniqueMessageIDs(self.messages)
    }

    func prependHistory(_ messages: [RenderedMessage]) {
        guard !messages.isEmpty else { return }
        self.messages = Self.sortedUnique(messages + self.messages)
        ChatDiagnostics.assertUniqueMessageIDs(self.messages)
    }

    func append(_ message: RenderedMessage) {
        if let existingIndex = messages.firstIndex(where: { $0.id == message.id }) {
            messages[existingIndex] = message
        } else {
            messages.append(message)
        }
        ChatDiagnostics.assertUniqueMessageIDs(messages)
    }

    func replace(messageID: String, with message: RenderedMessage) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index] = message
        ChatDiagnostics.assertUniqueMessageIDs(messages)
    }

    func updateStreamingText(messageID: String, text: String) {
        // Streaming is intentionally not implemented in the text-only baseline.
    }

    private static func sortedUnique(_ messages: [RenderedMessage]) -> [RenderedMessage] {
        var seen = Set<String>()
        var unique: [RenderedMessage] = []
        unique.reserveCapacity(messages.count)

        for message in messages where seen.insert(message.id).inserted {
            unique.append(message)
        }

        return unique
    }
}

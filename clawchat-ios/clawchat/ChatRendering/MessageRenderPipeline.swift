import Foundation

// MARK: - MessageRenderPipeline

/// Converts a raw `Message` value into a `RenderedMessage`.
///
/// Phase 1 rules:
/// - `content.type == "image"` → `.image` block (+ optional caption as `.text`)
/// - `content.type == "audio"` → `.audio` block
/// - everything else → `.text` block (Markdown / code not yet parsed)
enum MessageRenderPipeline {

    // MARK: Public API

    static func render(_ message: Message, currentUserID: String? = nil) -> RenderedMessage {
        let isMe = !message.senderId.isEmpty && message.senderId == currentUserID
        let blocks = makeBlocks(from: message.content)
        let sig = RenderedMessage.signature(for: message, currentUserID: currentUserID)
        return RenderedMessage(
            messageID: message.id,
            senderID: message.senderId,
            isMe: isMe,
            blocks: blocks.isEmpty ? [.loading] : blocks,
            renderSignature: sig
        )
    }

    // MARK: Private – Block Construction

    private static func makeBlocks(from content: MessageContent) -> [MessageBlock] {
        switch content.type.lowercased() {
        case "image":
            return imageBlocks(from: content)
        case "audio":
            return audioBlocks(from: content)
        default:
            return textBlocks(from: content)
        }
    }

    private static func textBlocks(from content: MessageContent) -> [MessageBlock] {
        guard let body = content.body, !body.isEmpty else { return [] }
        return [.text(TextBlock(content: body))]
    }

    private static func imageBlocks(from content: MessageContent) -> [MessageBlock] {
        let block = ImageBlock(
            url: content.imageURLString.flatMap { URL(string: $0) },
            altText: content.name
        )
        var blocks: [MessageBlock] = [.image(block)]
        if let caption = content.body, !caption.isEmpty {
            blocks.append(.text(TextBlock(content: caption)))
        }
        return blocks
    }

    private static func audioBlocks(from content: MessageContent) -> [MessageBlock] {
        let block = AudioBlock(
            url: content.url.flatMap { URL(string: $0) },
            durationSeconds: nil
        )
        return [.audio(block)]
    }
}

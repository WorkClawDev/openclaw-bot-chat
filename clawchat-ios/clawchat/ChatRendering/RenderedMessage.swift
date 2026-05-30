import Foundation

// MARK: - RenderedMessage

/// An immutable, display-ready representation of a single chat message.
///
/// Created by `MessageRenderPipeline` and consumed by the cell / preview layer.
/// The `renderSignature` lets callers skip re-renders when the source hasn't changed.
///
/// `codeHighlights` is the only mutable field: it starts empty and is filled in
/// asynchronously by `MessageRenderPipeline.renderWithHighlights` / `CodeHighlightService`.
/// `AttributedString` is `Equatable` but not `Hashable`, so `RenderedMessage` is
/// `Equatable + Sendable` but intentionally NOT `Hashable`.
struct RenderedMessage: Equatable, Sendable {
    let messageID: String
    let senderID: String
    let isMe: Bool
    let blocks: [MessageBlock]

    /// A lightweight fingerprint of the source `Message` used to detect stale renders.
    let renderSignature: String

    /// Syntax-highlighted `AttributedString` for each `CodeBlock`, keyed by `CodeBlock.id`.
    ///
    /// Populated asynchronously by `CodeHighlightService` after the initial synchronous
    /// render completes. Empty until highlights arrive; `RenderedCodeBlockView` shows a
    /// plain-text fallback until then (req 6).
    var codeHighlights: [String: AttributedString]

    init(
        messageID: String,
        senderID: String,
        isMe: Bool,
        blocks: [MessageBlock],
        renderSignature: String,
        codeHighlights: [String: AttributedString] = [:]
    ) {
        self.messageID = messageID
        self.senderID = senderID
        self.isMe = isMe
        self.blocks = blocks
        self.renderSignature = renderSignature
        self.codeHighlights = codeHighlights
    }
}

// MARK: - Signature Helper

extension RenderedMessage {
    /// Produces a deterministic signature from the fields that affect rendering.
    static func signature(for message: Message, currentUserID: String?) -> String {
        [
            message.id,
            currentUserID ?? "",
            message.content.type,
            message.content.body ?? "",
            message.content.url ?? "",
        ].joined(separator: "\u{1F}")
    }
}

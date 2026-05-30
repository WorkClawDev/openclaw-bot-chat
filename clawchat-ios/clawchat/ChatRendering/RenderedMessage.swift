import Foundation

// MARK: - RenderedMessage

/// An immutable, display-ready representation of a single chat message.
///
/// Created by `MessageRenderPipeline` and consumed by the preview / future cell layer.
/// The `renderSignature` lets callers skip re-renders when the source hasn't changed.
struct RenderedMessage: Equatable, Hashable, Sendable {
    let messageID: String
    let senderID: String
    let isMe: Bool
    let blocks: [MessageBlock]

    /// A lightweight fingerprint of the source `Message` used to detect stale renders.
    let renderSignature: String
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

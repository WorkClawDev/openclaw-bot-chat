import Foundation

// MARK: - Block Value Types

struct TextBlock: Equatable, Hashable, Sendable {
    let content: String
}

/// Phase 1: stored as raw text, not yet parsed by MarkdownUI.
struct MarkdownBlock: Equatable, Hashable, Sendable {
    let raw: String
}

/// Phase 2: monospaced display with language label, copy button, and horizontal scroll.
/// `id` is a deterministic key assigned by `MessageRenderPipeline` so that SwiftUI
/// can skip re-layout on fast scroll without identity churn.
struct CodeBlock: Equatable, Hashable, Sendable {
    let id: String
    let language: String?
    let source: String
}

// MARK: - Image Block

/// All fields needed by `LocalImageStore` to look up and download images,
/// pre-extracted from `Message`/`MessageContent`/`Asset` by `MessageRenderPipeline`.
/// Every property is a primitive `Sendable` type so `ImageLoadConfig` is `Sendable`.
struct ImageLoadConfig: Equatable, Hashable, Sendable {
    let messageID: String
    let imageURLString: String?
    let assetID: String?
    let assetObjectKey: String?
    let mimeType: String?
    let assetFileName: String?
    let contentName: String?
}

/// Phase 4: carries all display and loading metadata pre-computed by `MessageRenderPipeline`.
///
/// - `displaySize`: exact frame computed from image metadata; `nil` = use `aspectRatio` fallback.
/// - `loadConfig`: everything `LocalImageStore` needs to cache/download the image, so that
///   `RenderedImageBlockView` never has to read the original `Message`.
struct ImageBlock: Equatable, Hashable, Sendable {
    let altText: String?
    let loadConfig: ImageLoadConfig
    let displaySize: CGSize?     // pre-computed from asset/meta width×height constrained to max bounds
    let isSticker: Bool
    let aspectRatio: CGFloat     // fallback when displaySize is nil (default 4:3, stickers 1:1)
}

// MARK: - Audio Block

/// Phase 4: carries pre-computed display metrics so `RenderedAudioBlockView` can
/// render at a fixed size without reading `MessageContent` again.
struct AudioBlock: Equatable, Hashable, Sendable {
    let audioURLString: String?  // raw URL; the view resolves via APIClient at play time
    let durationSeconds: Int?
    let durationLabel: String    // e.g. "8\"" or "1.2 MB" or "语音"
    let bubbleWidth: CGFloat     // pre-computed from durationSeconds (98…200 pt range)
}

struct MessageImageInfo: Equatable, Hashable, Sendable {
    let url: URL?
    let altText: String?
}

// MARK: - MessageBlock

/// Represents a single renderable unit within a chat message.
///
/// Phase 1 produces `.text`, `.image`, and `.audio` blocks.
/// Phase 2 adds `.code` blocks (monospaced, no syntax highlighting).
/// Phase 3 produces `.markdown` blocks for all prose content.
/// Phase 4 enriches `.image` / `.audio` / `.code` with pre-computed display metrics.
enum MessageBlock: Equatable, Hashable, Sendable {
    case text(TextBlock)
    case markdown(MarkdownBlock)
    case code(CodeBlock)
    case image(ImageBlock)
    case audio(AudioBlock)
    case loading
    case error(String)
}

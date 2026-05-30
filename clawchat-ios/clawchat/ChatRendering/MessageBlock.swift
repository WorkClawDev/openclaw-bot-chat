import Foundation

// MARK: - Block Value Types

struct TextBlock: Equatable, Hashable, Sendable {
    let content: String
}

/// Phase 1: stored as raw text, not yet parsed by MarkdownUI.
struct MarkdownBlock: Equatable, Hashable, Sendable {
    let raw: String
}

/// Phase 1: stored as raw code, not yet syntax-highlighted.
struct CodeBlock: Equatable, Hashable, Sendable {
    let language: String?
    let source: String
}

struct ImageBlock: Equatable, Hashable, Sendable {
    let url: URL?
    let altText: String?
}

struct AudioBlock: Equatable, Hashable, Sendable {
    let url: URL?
    let durationSeconds: Double?
}

// MARK: - MessageBlock

/// Represents a single renderable unit within a chat message.
///
/// Phase 1 only produces `.text`, `.image`, and `.audio` blocks.
/// `.markdown` and `.code` are reserved for future phases.
enum MessageBlock: Equatable, Hashable, Sendable {
    case text(TextBlock)
    case markdown(MarkdownBlock)
    case code(CodeBlock)
    case image(ImageBlock)
    case audio(AudioBlock)
    case loading
    case error(String)
}

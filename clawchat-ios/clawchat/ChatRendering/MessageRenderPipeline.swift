import Foundation

// MARK: - MessageRenderPipeline

/// Converts a raw `Message` value into a `RenderedMessage`.
///
/// Phase 1: `.image` → `ImageBlock`, `.audio` → `AudioBlock`
/// Phase 2: text content code-fences are split into `CodeBlock`
/// Phase 3: all prose segments are emitted as `MarkdownBlock`
/// Phase 4: `ImageBlock` and `AudioBlock` carry pre-computed display metrics so
///           the view layer never re-reads `MessageContent` or starts parsing tasks.
enum MessageRenderPipeline {

    // MARK: Public API

    /// Synchronous render. Returns a `RenderedMessage` with empty `codeHighlights`.
    /// Use `renderWithHighlights` to also pre-compute syntax highlighting.
    static func render(_ message: Message, currentUserID: String? = nil) -> RenderedMessage {
        let isMe = !message.senderId.isEmpty && message.senderId == currentUserID
        let blocks = makeBlocks(from: message.content, messageID: message.id)
        let sig = RenderedMessage.signature(for: message, currentUserID: currentUserID)
        return RenderedMessage(
            messageID: message.id,
            senderID: message.senderId,
            isMe: isMe,
            blocks: blocks.isEmpty ? [.loading] : blocks,
            renderSignature: sig
        )
    }

    /// Async render that pre-computes syntax highlights for all `CodeBlock`s.
    ///
    /// Requirement 4: MessageRenderPipeline is responsible for pre-computing highlights
    /// before cells are displayed. Highlighting is delegated to `CodeHighlightService`
    /// (actor-isolated, LRU-cached) so no `.task` is needed in the view layer (req 7).
    ///
    /// - Parameters:
    ///   - palette: The colour palette determined by `isMe` and current colour scheme.
    static func renderWithHighlights(
        _ message: Message,
        currentUserID: String?,
        palette: CodeHighlightPalette
    ) async -> RenderedMessage {
        var rendered = render(message, currentUserID: currentUserID)

        var highlights: [String: AttributedString] = [:]
        for block in rendered.blocks {
            guard case .code(let cb) = block, !cb.source.isEmpty else { continue }
            if let text = await CodeHighlightService.shared.highlight(
                code: cb.source,
                language: cb.language,
                palette: palette
            ) {
                highlights[cb.id] = text
            }
        }

        rendered.codeHighlights = highlights
        return rendered
    }

    // MARK: Private – Block Construction

    private static func makeBlocks(from content: MessageContent, messageID: String) -> [MessageBlock] {
        switch content.type.lowercased() {
        case "image":
            return imageBlocks(from: content, messageID: messageID)
        case "audio", "voice":
            return audioBlocks(from: content)
        default:
            return markdownBlocks(from: content, messageID: messageID)
        }
    }

    // MARK: Image

    private static func imageBlocks(from content: MessageContent, messageID: String) -> [MessageBlock] {
        let asset = content.asset
        let isSticker = content.isSticker

        let natW = asset?.width ?? content.meta?["width"]?.intValue
        let natH = asset?.height ?? content.meta?["height"]?.intValue
        let aspectRatio = computeAspectRatio(w: natW, h: natH, isSticker: isSticker)
        let displaySize = computeDisplaySize(w: natW, h: natH, isSticker: isSticker)

        let loadConfig = ImageLoadConfig(
            messageID: messageID,
            imageURLString: content.imageURLString,
            assetID: asset?.id,
            assetObjectKey: asset?.objectKey,
            mimeType: asset?.mimeType,
            assetFileName: asset?.fileName,
            contentName: content.name
        )

        let block = ImageBlock(
            altText: content.name,
            loadConfig: loadConfig,
            displaySize: displaySize,
            isSticker: isSticker,
            aspectRatio: aspectRatio
        )

        var blocks: [MessageBlock] = [.image(block)]
        if let caption = content.body, !caption.isEmpty, !isSticker {
            blocks.append(.text(TextBlock(content: caption)))
        }
        return blocks
    }

    /// Constrain a natural image size to the maximum display bounds, preserving aspect ratio.
    private static func computeDisplaySize(w: Int?, h: Int?, isSticker: Bool) -> CGSize? {
        guard let w, let h, w > 0, h > 0 else { return nil }
        let maxW: CGFloat = isSticker ? 160 : 280
        let maxH: CGFloat = isSticker ? 160 : 320
        let ratio = CGFloat(w) / CGFloat(h)
        if ratio > maxW / maxH {
            return CGSize(width: maxW, height: (maxW / ratio).rounded())
        } else {
            return CGSize(width: (maxH * ratio).rounded(), height: maxH)
        }
    }

    /// Fallback aspect ratio when natural dimensions are not available.
    private static func computeAspectRatio(w: Int?, h: Int?, isSticker: Bool) -> CGFloat {
        if let w, let h, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
        return isSticker ? 1.0 : 4.0 / 3.0
    }

    // MARK: Audio

    private static func audioBlocks(from content: MessageContent) -> [MessageBlock] {
        let durationSeconds = content.audioDurationSeconds
        let block = AudioBlock(
            audioURLString: content.audioURLString,
            durationSeconds: durationSeconds,
            durationLabel: audioDurationLabel(content: content, durationSeconds: durationSeconds),
            bubbleWidth: audioBubbleWidth(durationSeconds: durationSeconds)
        )
        return [.audio(block)]
    }

    private static func audioDurationLabel(content: MessageContent, durationSeconds: Int?) -> String {
        if let d = durationSeconds { return "\(d)\"" }
        let size = content.size ?? content.asset?.size
        if let size, size > 0 {
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        return "语音"
    }

    private static func audioBubbleWidth(durationSeconds: Int?) -> CGFloat {
        guard let d = durationSeconds else { return 118 }
        let clamped = min(max(d, 1), 60)
        return 98.0 + CGFloat(clamped) * 1.7
    }

    // MARK: Markdown + Code Fence Parser

    /// Splits `body` into an alternating sequence of `.markdown` and `.code` blocks.
    ///
    /// Algorithm: `components(separatedBy: "```")` produces alternating segments where
    /// even-indexed segments are prose (→ `MarkdownBlock`) and odd-indexed segments are
    /// code-fence bodies (first line = language tag, remaining lines = source → `CodeBlock`).
    ///
    /// The O(n) split is done once in the pipeline; the view layer receives typed blocks
    /// and never re-parses content.
    private static func markdownBlocks(from content: MessageContent, messageID: String) -> [MessageBlock] {
        guard let body = content.body, !body.isEmpty else { return [] }
        return parseMarkdownBody(body, messageID: messageID)
    }

    private static func parseMarkdownBody(_ body: String, messageID: String) -> [MessageBlock] {
        guard body.contains("```") else {
            return [.markdown(MarkdownBlock(raw: body))]
        }

        let parts = body.components(separatedBy: "```")
        var blocks: [MessageBlock] = []
        var codeIndex = 0

        for (i, part) in parts.enumerated() {
            if i.isMultiple(of: 2) {
                let trimmed = part.trimmingCharacters(in: .newlines)
                if !trimmed.isEmpty {
                    blocks.append(.markdown(MarkdownBlock(raw: trimmed)))
                }
            } else {
                let id = "\(messageID)-cb-\(codeIndex)"
                if let nlIdx = part.firstIndex(of: "\n") {
                    let lang   = String(part[part.startIndex..<nlIdx]).trimmingCharacters(in: .whitespaces)
                    let source = String(part[part.index(after: nlIdx)...]).trimmingCharacters(in: .newlines)
                    blocks.append(.code(CodeBlock(
                        id: id,
                        language: lang.isEmpty ? nil : lang,
                        source: source
                    )))
                } else {
                    let lang = part.trimmingCharacters(in: .whitespaces)
                    blocks.append(.code(CodeBlock(
                        id: id,
                        language: lang.isEmpty ? nil : lang,
                        source: ""
                    )))
                }
                codeIndex += 1
            }
        }

        return blocks.isEmpty ? [.markdown(MarkdownBlock(raw: body))] : blocks
    }
}

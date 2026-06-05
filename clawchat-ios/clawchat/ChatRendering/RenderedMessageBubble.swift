import SwiftUI
import UIKit
import MarkdownUI

// MARK: - renderedChatTheme

/// Self-contained MarkdownUI theme used exclusively by `RenderedMessageBubble`.
///
/// This is intentionally separate from `rcmsChatTheme` (in ChatRoomView.swift) so that
/// `RenderedMessageBubble.swift` has zero dependency on `ChatHighlightedCodeView`.
/// The pipeline always strips fenced code blocks into `CodeBlock` values before this
/// view sees the text, so the `.codeBlock` fallback here should never trigger in practice.
extension Theme {
    static func renderedChatTheme(isMe: Bool) -> Theme {
        let fg: Color = isMe ? .white : Color.rcmsTextPrimary
        let fgSecondary: Color = isMe ? Color.white.opacity(0.7) : Color.rcmsTextSecondary
        let codeBg: Color = isMe ? Color.white.opacity(0.15) : Color(UIColor.secondarySystemGroupedBackground)

        return Theme()
            .text {
                ForegroundColor(fg)
                FontSize(15)
            }
            .strong {
                FontWeight(.semibold)
                ForegroundColor(fg)
            }
            .emphasis {
                FontStyle(.italic)
                ForegroundColor(fg)
            }
            .link {
                ForegroundColor(isMe ? .white : Color.rcmsAccent)
                UnderlineStyle(.single)
            }
            .strikethrough {
                StrikethroughStyle(.single)
                ForegroundColor(fgSecondary)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(13)
                ForegroundColor(isMe ? Color.white.opacity(0.9) : Color.rcmsAccent)
                BackgroundColor(codeBg)
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownMargin(top: 0, bottom: 0)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownMargin(top: 8, bottom: 4)
                    .markdownTextStyle {
                        FontSize(20)
                        FontWeight(.bold)
                        ForegroundColor(fg)
                    }
            }
            .heading2 { configuration in
                configuration.label
                    .markdownMargin(top: 6, bottom: 4)
                    .markdownTextStyle {
                        FontSize(18)
                        FontWeight(.semibold)
                        ForegroundColor(fg)
                    }
            }
            .heading3 { configuration in
                configuration.label
                    .markdownMargin(top: 4, bottom: 2)
                    .markdownTextStyle {
                        FontSize(16)
                        FontWeight(.medium)
                        ForegroundColor(fg)
                    }
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 1, bottom: 1)
            }
            .blockquote { configuration in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isMe ? Color.white.opacity(0.5) : Color.rcmsAccent.opacity(0.5))
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle {
                            ForegroundColor(fgSecondary)
                            FontStyle(.italic)
                        }
                }
            }
            .codeBlock { configuration in
                // Fallback: pipeline should have already extracted all code fences.
                // If somehow reached, render as plain scrollable monospaced text.
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(configuration.content)
                        .font(ChatCodeTypography.codeFont(size: 13))
                        .foregroundStyle(isMe ? Color.white.opacity(0.9) : Color.rcmsTextPrimary)
                        .fixedSize(horizontal: true, vertical: false)
                        .lineSpacing(3)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .background(codeBg)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
    }
}

// MARK: - RenderedMessageBubble

/// The message-content portion of a chat bubble, driven entirely by a pre-computed
/// `RenderedMessage`. The surrounding chrome (avatar, sender label, timestamp) lives
/// in `ChatBubbleRow` and is NOT part of this view.
///
/// Design constraints (Phase 4):
/// - No code highlighting `.task` — `RenderedCodeBlockView` renders plain monospaced text.
/// - No markdown re-parsing — `MarkdownBlock.raw` is passed directly to MarkdownUI.
/// - No `Message` reference — all data comes from the typed `MessageBlock` values.
/// - Image loading `.task` is intentional and acceptable (network I/O, not parsing).
struct RenderedMessageBubble: View {
    let rendered: RenderedMessage
    let isMe: Bool
    let onPreviewImage: (() -> Void)?

    var body: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 6) {
            ForEach(Array(rendered.blocks.enumerated()), id: \.offset) { _, block in
                RenderedBlockView(
                    block: block,
                    isMe: isMe,
                    onPreviewImage: onPreviewImage,
                    codeHighlights: rendered.codeHighlights
                )
            }
        }
    }
}

// MARK: - Block Dispatcher

private struct RenderedBlockView: View {
    let block: MessageBlock
    let isMe: Bool
    let onPreviewImage: (() -> Void)?
    /// Pre-computed highlights from `RenderedMessage.codeHighlights`, keyed by `CodeBlock.id`.
    /// Passed down by `RenderedMessageBubble`; never computed here (req 7).
    let codeHighlights: [String: AttributedString]

    var body: some View {
        switch block {
        case .text(let b):
            textBubble(b.content)

        case .markdown(let b):
            markdownBubble(b)

        case .code(let b):
            RenderedCodeBlockView(
                block: b,
                isMe: isMe,
                highlightedText: codeHighlights[b.id]
            )

        case .image(let b):
            RenderedImageBlockView(block: b, isMe: isMe, onPreviewImage: onPreviewImage)

        case .audio(let b):
            RenderedAudioBlockView(block: b, isMe: isMe)

        case .loading:
            ProgressView()
                .padding()

        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(8)
        }
    }

    private func textBubble(_ text: String) -> some View {
        let shape = BubbleShape(isMe: isMe)
        return Text(text)
            .font(.system(size: 15))
            .foregroundStyle(isMe ? .white : Color.rcmsTextPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isMe ? Color.rcmsAccent : Color.rcmsIncomingBubble)
            .clipShape(shape)
            .contentShape(shape)
            .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
    }

    private func markdownBubble(_ block: MarkdownBlock) -> some View {
        let shape = BubbleShape(isMe: isMe)
        return Group {
            if hasComplexMarkdown(block.raw) {
                Markdown(block.raw)
                    .markdownTheme(.renderedChatTheme(isMe: isMe))
                    .tint(isMe ? .white : Color.rcmsAccent)
            } else {
                // 对于纯文字 / 行内格式，用原生 Text：尺寸精准，无额外垂直内边距。
                let attrStr = (try? AttributedString(
                    markdown: block.raw,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                )) ?? AttributedString(block.raw)
                Text(attrStr)
                    .font(.system(size: 15))
                    .foregroundStyle(isMe ? Color.white : Color.rcmsTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isMe ? Color.rcmsAccent : Color.rcmsIncomingBubble)
        .clipShape(shape)
        .contentShape(shape)
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
    }

    /// 检测是否包含块级 Markdown（标题、列表、引用、表格）。
    /// 仅行内格式（加粗、斜体、行内代码、链接）用原生 Text 即可处理。
    private func hasComplexMarkdown(_ text: String) -> Bool {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("#") ||
                    trimmed.hasPrefix("- ") ||
                    trimmed.hasPrefix("* ") ||
                    trimmed.hasPrefix("> ") ||
                    trimmed.hasPrefix("| ") ||
                    isOrderedListLine(trimmed)
            }
    }

    private func isOrderedListLine(_ line: String) -> Bool {
        guard let dotIndex = line.firstIndex(of: "."),
              dotIndex > line.startIndex,
              line.index(after: dotIndex) < line.endIndex,
              line[line.index(after: dotIndex)] == " "
        else {
            return false
        }
        return line[..<dotIndex].allSatisfy(\.isNumber)
    }
}

// MARK: - Code Block

/// Renders a `CodeBlock` with language label, copy button, and horizontal scroll.
///
/// Requirements:
/// - No `.task`, `.onAppear`, or any async call in this view (req 7).
/// - `highlightedText` is pre-computed by `CodeHighlightService` via the pipeline and
///   delivered by the Coordinator; this view only DISPLAYS it.
/// - Font, size, lineSpacing, and padding are identical for plain and highlighted paths
///   because they are applied to the outer `Group`, not inside the `if/else` (req 8).
/// - Copy button (req 14) is always available regardless of highlight state.
struct RenderedCodeBlockView: View {
    let block: CodeBlock
    let isMe: Bool
    /// Pre-computed syntax-highlighted text. `nil` until highlights arrive (plain fallback shown).
    /// Default `nil` keeps call sites in `MessagePreviewView` backward-compatible.
    let highlightedText: AttributedString?

    init(block: CodeBlock, isMe: Bool, highlightedText: AttributedString? = nil) {
        self.block = block
        self.isMe = isMe
        self.highlightedText = highlightedText
    }

    @State private var copied = false

    private var displayLang: String { block.language?.lowercased() ?? "plaintext" }

    private var headerFg: Color {
        isMe ? Color.white.opacity(0.7) : Color.rcmsTextSecondary
    }
    private var headerBg: Color {
        isMe ? Color.black.opacity(0.15) : Color(UIColor.tertiarySystemGroupedBackground)
    }
    private var bodyBg: Color {
        isMe ? Color.black.opacity(0.2) : Color.rcmsCodeBlockBackground
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ─────────────────────────────────────────────
            HStack(spacing: 0) {
                Text(displayLang)
                    .font(ChatCodeTypography.labelFont(size: 11))
                    .foregroundStyle(headerFg)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 32, alignment: .leading)

                Spacer(minLength: 0)

                Button {
                    UIPasteboard.general.string = block.source
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(copied ? .green : headerFg)
                        .frame(width: 36, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.15), value: copied)
            }
            .background(headerBg)

            Divider()

            // ── Code body ─────────────────────────────────────────
            // Font, lineSpacing, and padding are applied to the outer Group so
            // layout is pixel-identical for plain and highlighted paths (req 8).
            // No .task or .onAppear here — req 7.
            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    if let highlighted = highlightedText {
                        // HighlightSwift only adds foreground color attributes; the
                        // .font() modifier below is the sole authority on typeface (req 9).
                        Text(highlighted)
                    } else {
                        Text(verbatim: block.source.isEmpty ? " " : block.source)
                            .foregroundStyle(isMe ? Color.white.opacity(0.9) : Color.rcmsTextPrimary)
                    }
                }
                .font(ChatCodeTypography.codeFont(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .lineSpacing(3)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 10)
            }
            .background(bodyBg)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isMe ? Color.white.opacity(0.12) : Color.rcmsHairline, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
        .padding(.vertical, 2)
    }
}

// MARK: - Image Block

/// Renders an `ImageBlock` using pre-computed `displaySize`/`aspectRatio` for
/// stable layout before the image loads. Downloads via `LocalImageStore` using
/// the pre-extracted `ImageLoadConfig` — no `Message` needed.
///
/// The `.task(id:)` here is network I/O for image loading, NOT a syntax-highlight
/// task — requirement 4 (no code-highlight tasks in cells) is not violated.
struct RenderedImageBlockView: View {
    let block: ImageBlock
    let isMe: Bool
    let onPreviewImage: (() -> Void)?

    @State private var cachedImage: UIImage?
    @State private var isLoading = false
    @State private var didFail = false

    private var maxW: CGFloat { block.isSticker ? 160 : 280 }
    private var maxH: CGFloat { block.isSticker ? 160 : 320 }
    private var cornerRadius: CGFloat { block.isSticker ? 18 : 20 }

    var body: some View {
        let thumbnail = imageContent
            .sizedForDisplay(block: block)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: block.loadConfig.imageURLString ?? block.loadConfig.messageID) {
                await loadImage()
            }

        if let onPreviewImage {
            thumbnail
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .onTapGesture { onPreviewImage() }
        } else {
            thumbnail
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let img = cachedImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
        } else {
            imagePlaceholder
        }
    }

    private var imagePlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.rcmsSurfaceElevated)

            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.rcmsTextSecondary)

                Text(placeholderLabel)
                    .font(.caption)
                    .foregroundStyle(Color.rcmsTextSecondary)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholderLabel: String {
        if didFail || block.loadConfig.imageURLString == nil { return "图片不可用" }
        return isLoading ? "图片加载中..." : "准备图片..."
    }

    @MainActor
    private func loadImage() async {
        guard cachedImage == nil else { return }

        if let url = LocalImageStore.shared.cachedFileURL(for: block.loadConfig),
           let img = await decodeImage(at: url) {
            cachedImage = img
            return
        }

        isLoading = true
        defer { isLoading = false }

        guard let url = await LocalImageStore.shared.ensureCachedImage(for: block.loadConfig),
              let img = await decodeImage(at: url)
        else {
            didFail = true
            return
        }

        cachedImage = img
    }

    private func decodeImage(at url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: url.path)
        }.value
    }
}

// MARK: - Image Sizing Helper

private extension View {
    /// Applies the pre-computed `displaySize` as a fixed frame when available,
    /// or falls back to `aspectRatio + maxFrame` to prevent layout jitter.
    @ViewBuilder
    func sizedForDisplay(block: ImageBlock) -> some View {
        if let size = block.displaySize {
            self.frame(width: size.width, height: size.height)
        } else {
            let maxW: CGFloat = block.isSticker ? 160 : 280
            let maxH: CGFloat = block.isSticker ? 160 : 320
            self
                .aspectRatio(block.aspectRatio, contentMode: .fit)
                .frame(maxWidth: maxW, maxHeight: maxH)
        }
    }
}

// MARK: - Audio Block

/// Renders an `AudioBlock` using pre-computed `durationLabel` and `bubbleWidth`.
/// Uses `ChatAudioPlaybackController` (made internal in ChatRoomView) for playback.
struct RenderedAudioBlockView: View {
    let block: AudioBlock
    let isMe: Bool

    @StateObject private var playback = ChatAudioPlaybackController()

    private var resolvedURL: URL? {
        APIClient.shared.resolvedURL(from: block.audioURLString)
    }

    var body: some View {
        Button {
            playback.toggle(url: resolvedURL)
        } label: {
            HStack(spacing: 10) {
                if !isMe {
                    playbackIcon
                    ChatAudioWaveform(isPlaying: playback.isPlaying, isMe: isMe)
                    Spacer(minLength: 4)
                    durationText
                } else {
                    durationText
                    Spacer(minLength: 4)
                    ChatAudioWaveform(isPlaying: playback.isPlaying, isMe: isMe)
                    playbackIcon
                }
            }
            .frame(width: block.bubbleWidth, alignment: isMe ? .trailing : .leading)
            .frame(minHeight: 32)
            .padding(.horizontal, 13)
            .padding(.vertical, 5)
            .background(isMe ? Color.rcmsAccent : Color.rcmsIncomingBubble)
            .clipShape(BubbleShape(isMe: isMe))
            .contentShape(BubbleShape(isMe: isMe))
            .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .onDisappear { playback.pause() }
    }

    private var durationText: some View {
        Text(block.durationLabel)
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(isMe ? .white : Color.rcmsTextPrimary)
            .monospacedDigit()
    }

    private var playbackIcon: some View {
        ZStack {
            Circle()
                .fill(isMe ? Color.white.opacity(0.2) : Color.rcmsAccent.opacity(0.12))
                .frame(width: 32, height: 32)
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isMe ? .white : Color.rcmsAccent)
                .offset(x: playback.isPlaying ? 0 : 1)
        }
    }

    private var accessibilityLabel: String {
        playback.isPlaying ? "暂停语音：\(block.durationLabel)" : "播放语音：\(block.durationLabel)"
    }
}

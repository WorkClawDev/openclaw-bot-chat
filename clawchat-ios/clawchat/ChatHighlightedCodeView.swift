import SwiftUI
import HighlightSwift

struct ChatHighlightedCodeView: View {
    let code: String
    let language: String?
    let isMe: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var highlightedText: AttributedString?

    private let highlighter = Highlight()

    var body: some View {
        Group {
            if let highlightedText {
                Text(highlightedText)
            } else {
                Text(verbatim: code)
                    .foregroundStyle(isMe ? Color.white.opacity(0.92) : Color.rcmsTextStrong)
            }
        }
        .font(ChatCodeTypography.codeFont())
        .textSelection(.enabled)
        .task(id: renderKey) {
            await renderHighlightedText()
        }
    }

    private var renderKey: String {
        let palette = isMe ? "sent" : (colorScheme == .dark ? "received-dark" : "received-light")
        return "\(normalizedLanguage ?? "auto")::\(palette)::\(code)"
    }

    private var normalizedLanguage: String? {
        let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    @MainActor
    private func renderHighlightedText() async {
        if let cached = Self.cachedHighlight(for: renderKey) {
            highlightedText = cached
            return
        }

        do {
            let colors = HighlightColors.custom(css: highlightCSS)
            let renderedText: AttributedString

            if let normalizedLanguage {
                renderedText = try await highlighter.attributedText(
                    code,
                    language: normalizedLanguage,
                    colors: colors
                )
            } else {
                renderedText = try await highlighter.attributedText(
                    code,
                    colors: colors
                )
            }

            highlightedText = renderedText
            Self.cacheHighlight(renderedText, for: renderKey)
        } catch {
            highlightedText = nil
        }
    }

    @MainActor
    private static var highlightCache: [String: AttributedString] = [:]

    @MainActor
    private static var highlightCacheOrder: [String] = []

    private static let highlightCacheLimit = 80

    @MainActor
    private static func cachedHighlight(for key: String) -> AttributedString? {
        highlightCache[key]
    }

    @MainActor
    private static func cacheHighlight(_ value: AttributedString, for key: String) {
        if highlightCache[key] == nil {
            highlightCacheOrder.append(key)
        }
        highlightCache[key] = value

        while highlightCacheOrder.count > highlightCacheLimit {
            let oldestKey = highlightCacheOrder.removeFirst()
            highlightCache[oldestKey] = nil
        }
    }

    private static let sentCodeCSS = """
    .hljs { color: #f8fafc; }
    .hljs-comment, .hljs-quote { color: #94a3b8; }
    .hljs-keyword, .hljs-selector-tag, .hljs-literal { color: #fde047; }
    .hljs-string, .hljs-doctag, .hljs-regexp { color: #86efac; }
    .hljs-number, .hljs-symbol, .hljs-bullet { color: #c4b5fd; }
    .hljs-title, .hljs-section, .hljs-function .hljs-title { color: #7dd3fc; }
    .hljs-type, .hljs-class .hljs-title, .hljs-built_in { color: #fda4af; }
    .hljs-meta, .hljs-meta .hljs-keyword, .hljs-selector-id { color: #fdba74; }
    .hljs-attr, .hljs-attribute, .hljs-property { color: #67e8f9; }
    """

    private static let receivedCodeCSS = """
    .hljs { color: #0f172a; }
    .hljs-comment, .hljs-quote { color: #64748b; }
    .hljs-keyword, .hljs-selector-tag, .hljs-literal { color: #7c3aed; }
    .hljs-string, .hljs-doctag, .hljs-regexp { color: #16a34a; }
    .hljs-number, .hljs-symbol, .hljs-bullet { color: #ea580c; }
    .hljs-title, .hljs-section, .hljs-function .hljs-title { color: #2563eb; }
    .hljs-type, .hljs-class .hljs-title, .hljs-built_in { color: #0891b2; }
    .hljs-meta, .hljs-meta .hljs-keyword, .hljs-selector-id { color: #dc2626; }
    .hljs-attr, .hljs-attribute, .hljs-property { color: #0f766e; }
    """

    private static let receivedDarkCodeCSS = """
    .hljs { color: #e2e8f0; }
    .hljs-comment, .hljs-quote { color: #94a3b8; }
    .hljs-keyword, .hljs-selector-tag, .hljs-literal { color: #c4b5fd; }
    .hljs-string, .hljs-doctag, .hljs-regexp { color: #86efac; }
    .hljs-number, .hljs-symbol, .hljs-bullet { color: #fdba74; }
    .hljs-title, .hljs-section, .hljs-function .hljs-title { color: #7dd3fc; }
    .hljs-type, .hljs-class .hljs-title, .hljs-built_in { color: #fda4af; }
    .hljs-meta, .hljs-meta .hljs-keyword, .hljs-selector-id { color: #f87171; }
    .hljs-attr, .hljs-attribute, .hljs-property { color: #67e8f9; }
    """

    private var highlightCSS: String {
        if isMe {
            return Self.sentCodeCSS
        }
        return colorScheme == .dark ? Self.receivedDarkCodeCSS : Self.receivedCodeCSS
    }
}

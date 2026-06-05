import Foundation
import HighlightSwift

// MARK: - CodeHighlightPalette

/// The three color palettes used for code syntax highlighting.
///
/// - `sent`: for outgoing (isMe) bubbles — light-on-dark palette.
/// - `receivedLight`: for incoming bubbles in light mode.
/// - `receivedDark`: for incoming bubbles in dark mode.
///
/// Cache key requirement (req 13): cache key must include code, language, AND palette.
nonisolated enum CodeHighlightPalette: String, Sendable {
    case sent
    case receivedLight
    case receivedDark

    /// Returns the HLJS CSS string for this palette.
    ///
    /// Requirement 9: only `color` properties are modified; font-size, font-weight,
    /// line-height, and margin are untouched so layout is entirely controlled by SwiftUI.
    var css: String {
        switch self {
        case .sent:          return CodeHighlightPalette.sentCSS
        case .receivedLight: return CodeHighlightPalette.receivedLightCSS
        case .receivedDark:  return CodeHighlightPalette.receivedDarkCSS
        }
    }

    // ── Palettes ────────────────────────────────────────────────────────────────
    // All entries only set `color`; no font-size / font-weight / line-height changes.

    private static let sentCSS = """
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

    private static let receivedLightCSS = """
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

    private static let receivedDarkCSS = """
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
}

// MARK: - CodeHighlightService

/// Actor-isolated service for syntax highlighting using HighlightSwift.
///
/// Design rules (from requirements):
/// - Actor isolation ensures the cache and `Highlight()` instance are thread-safe.
/// - Cache key includes `code + language + palette` (req 13).
/// - LRU eviction at 120 entries.
/// - Callers receive `AttributedString?` — nil means highlighting failed or source was empty.
/// - No SwiftUI / UIKit knowledge here; this is pure data transformation.
actor CodeHighlightService {

    // MARK: Shared singleton

    static let shared = CodeHighlightService()

    // MARK: Private state

    private let highlighter = Highlight()
    private var cache: [String: AttributedString] = [:]
    private var cacheOrder: [String] = []
    private static let cacheLimit = 120

    // MARK: - Public API

    /// Returns a syntax-highlighted `AttributedString` for the given code.
    ///
    /// The result only contains foreground color attributes; font, size, and spacing
    /// are left to the caller's SwiftUI modifiers (req 9).
    func highlight(
        code: String,
        language: String?,
        palette: CodeHighlightPalette
    ) async -> AttributedString? {
        guard !code.isEmpty else { return nil }

        let key = cacheKey(code: code, language: language, palette: palette)
        if let cached = cache[key] {
            markRecentlyUsed(key)
            return cached
        }

        let colors = HighlightColors.custom(css: palette.css)
        let result: AttributedString
        do {
            if let lang = normalizedLanguage(language) {
                result = try await highlighter.attributedText(code, language: lang, colors: colors)
            } else {
                result = try await highlighter.attributedText(code, colors: colors)
            }
        } catch {
            return nil
        }

        store(result, for: key)
        return result
    }

    // MARK: - Private helpers

    private func cacheKey(code: String, language: String?, palette: CodeHighlightPalette) -> String {
        // req 13: key must include code, language, and palette
        "\(normalizedLanguage(language) ?? "auto")::\(palette.rawValue)::\(code)"
    }

    private func normalizedLanguage(_ language: String?) -> String? {
        let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private func store(_ value: AttributedString, for key: String) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = value
        while cacheOrder.count > Self.cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    private func markRecentlyUsed(_ key: String) {
        guard let index = cacheOrder.firstIndex(of: key) else { return }
        cacheOrder.remove(at: index)
        cacheOrder.append(key)
    }
}

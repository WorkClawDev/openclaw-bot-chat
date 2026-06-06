import Foundation
import UIKit

@MainActor
final class MessageLayoutCacheV2 {
    struct Key: Hashable {
        let messageID: String
        let contentHash: Int
        let isOutgoing: Bool
        let width: Int
        let contentSizeCategory: UIContentSizeCategory
    }

    private var layouts: [Key: MessageLayoutV2] = [:]

    func layout(for key: Key) -> MessageLayoutV2? {
        layouts[key]
    }

    func store(_ layout: MessageLayoutV2, for key: Key) {
        layouts[key] = layout
    }

    func removeAll() {
        layouts.removeAll()
    }
}

@MainActor
final class MessageRenderCoordinatorV2 {
    private let layoutCache: MessageLayoutCacheV2

    init() {
        self.layoutCache = MessageLayoutCacheV2()
    }

    init(layoutCache: MessageLayoutCacheV2) {
        self.layoutCache = layoutCache
    }

    func renderPage(_ messages: [ChatMessageV2], containerWidth: CGFloat, traitCollection: UITraitCollection) -> [RenderedMessageV2] {
        messages.map { render($0, containerWidth: containerWidth, traitCollection: traitCollection) }
    }

    func render(_ message: ChatMessageV2, containerWidth: CGFloat, traitCollection: UITraitCollection) -> RenderedMessageV2 {
        let displayScale = max(traitCollection.displayScale, 1)
        let key = MessageLayoutCacheV2.Key(
            messageID: message.id,
            contentHash: message.layoutHashValue,
            isOutgoing: message.isOutgoing,
            width: Int((containerWidth * displayScale).rounded()),
            contentSizeCategory: traitCollection.preferredContentSizeCategory
        )

        if let cached = layoutCache.layout(for: key) {
            return RenderedMessageV2(
                id: message.id,
                sequence: message.sequence,
                isOutgoing: message.isOutgoing,
                blocks: message.blocks,
                sender: message.sender,
                status: message.status,
                layout: cached
            )
        }

        let layout = makeLayout(for: message, containerWidth: containerWidth)
        layoutCache.store(layout, for: key)
        return RenderedMessageV2(
            id: message.id,
            sequence: message.sequence,
            isOutgoing: message.isOutgoing,
            blocks: message.blocks,
            sender: message.sender,
            status: message.status,
            layout: layout
        )
    }

    private func makeLayout(for message: ChatMessageV2, containerWidth: CGFloat) -> MessageLayoutV2 {
        let safeWidth = max(containerWidth, 320)
        let horizontalInset: CGFloat = 12
        let verticalInset: CGFloat = 5
        let avatarSize: CGFloat = 44
        let avatarGap: CGFloat = 8
        let maxBubbleWidth = min(300, floor(safeWidth * 0.72))
        let contentX = message.isOutgoing ? horizontalInset : horizontalInset + avatarSize + avatarGap

        var y = verticalInset
        var blockLayouts: [BlockLayoutV2] = []
        if let sender = message.sender, sender.showsName {
            let senderSize = senderNameSize(for: sender, maxBubbleWidth: maxBubbleWidth)
            blockLayouts.append(BlockLayoutV2(
                id: Self.senderLayoutID(for: message.id),
                frame: CGRect(x: contentX + 4, y: y, width: senderSize.width, height: senderSize.height)
            ))
            y += senderSize.height + 4
        }

        for block in message.blocks {
            let blockSize = size(for: block, maxBubbleWidth: maxBubbleWidth)
            let blockX = message.isOutgoing
                ? safeWidth - horizontalInset - blockSize.width
                : horizontalInset + avatarSize + avatarGap
            let blockFrame = CGRect(x: blockX, y: y, width: blockSize.width, height: blockSize.height)
            blockLayouts.append(BlockLayoutV2(id: block.id, frame: blockFrame))
            y = blockFrame.maxY + 8
        }

        if !blockLayouts.isEmpty {
            y -= 8
        }

        if let status = message.status, !status.displayText.isEmpty {
            let statusSize = statusSize(for: status)
            let statusX = message.isOutgoing
                ? safeWidth - horizontalInset - statusSize.width - 4
                : contentX + 4
            blockLayouts.append(BlockLayoutV2(
                id: Self.statusLayoutID(for: message.id),
                frame: CGRect(x: statusX, y: y + 4, width: statusSize.width, height: statusSize.height)
            ))
            y += statusSize.height + 4
        }

        let itemHeight = ceil(max(avatarSize + verticalInset * 2, y + verticalInset))
        if message.sender != nil {
            let avatarY = max(verticalInset, itemHeight - verticalInset - avatarSize)
            blockLayouts.append(BlockLayoutV2(
                id: Self.avatarLayoutID(for: message.id),
                frame: CGRect(x: horizontalInset, y: avatarY, width: avatarSize, height: avatarSize)
            ))
        }

        return MessageLayoutV2(
            itemSize: CGSize(width: safeWidth, height: itemHeight),
            blockLayouts: blockLayouts
        )
    }

    private func size(for block: MessageBlockContentV2, maxBubbleWidth: CGFloat) -> CGSize {
        switch block {
        case .text(let text):
            return textSize(for: text, maxBubbleWidth: maxBubbleWidth)
        case .code(let code):
            return codeSize(for: code, maxBubbleWidth: maxBubbleWidth)
        case .table(let table):
            return tableSize(for: table, maxBubbleWidth: maxBubbleWidth)
        case .image(let image):
            return imageSize(for: image, maxBubbleWidth: maxBubbleWidth)
        case .audio(let audio):
            return audioSize(for: audio, maxBubbleWidth: maxBubbleWidth)
        }
    }

    private func textSize(for block: TextBlockContentV2, maxBubbleWidth: CGFloat) -> CGSize {
        let textInsetX: CGFloat = 12
        let textInsetY: CGFloat = 10
        let maxTextWidth = max(1, maxBubbleWidth - textInsetX * 2)
        let attributed = MessageTextFormatterV2.attributedString(
            for: block.text.isEmpty ? " " : block.text,
            isOutgoing: false,
            rendersMarkdown: block.isMarkdown
        )
        let measured = attributed.boundingRect(
            with: CGSize(width: maxTextWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let textWidth = min(maxTextWidth, ceil(measured.width))
        let textHeight = ceil(measured.height)
        return CGSize(
            width: min(maxBubbleWidth, max(44, textWidth + textInsetX * 2)),
            height: max(40, textHeight + textInsetY * 2)
        )
    }

    private func codeSize(for block: CodeBlockContentV2, maxBubbleWidth: CGFloat) -> CGSize {
        let horizontalPadding: CGFloat = 12
        let verticalPadding: CGFloat = 14
        let languageHeight: CGFloat = block.language == nil ? 0 : 28
        let codeFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let maxCodeWidth = max(1, maxBubbleWidth - horizontalPadding * 2)
        let lineCount = max(1, block.code.components(separatedBy: .newlines).count)
        let lineHeight = ceil(codeFont.lineHeight + 3)
        let contentHeight = CGFloat(lineCount) * lineHeight
        let contentWidth = min(maxCodeWidth, max(84, ChatCodeSyntaxHighlighterV2.contentWidth(for: block.code)))
        return CGSize(
            width: max(120, min(maxBubbleWidth, contentWidth + horizontalPadding * 2)),
            height: max(48, ceil(contentHeight + verticalPadding * 2 + languageHeight))
        )
    }

    private func tableSize(for block: TableBlockContentV2, maxBubbleWidth: CGFloat) -> CGSize {
        let metrics = ChatTableLayoutMetricsV2.metrics(for: block)
        let outerWidth = min(maxBubbleWidth, max(160, metrics.contentWidth))
        return CGSize(
            width: ceil(outerWidth),
            height: ceil(metrics.contentHeight)
        )
    }

    private func imageSize(for block: ImageBlockContentV2, maxBubbleWidth: CGFloat) -> CGSize {
        let maxWidth = block.isSticker ? min(160, maxBubbleWidth) : min(280, maxBubbleWidth)
        let maxHeight: CGFloat = block.isSticker ? 160 : 320
        let aspectRatio = min(max(block.aspectRatio, 0.25), 4)

        if maxWidth / maxHeight > aspectRatio {
            let height = max(72, maxHeight)
            return CGSize(width: ceil(height * aspectRatio), height: height)
        } else {
            let width = max(72, maxWidth)
            return CGSize(width: width, height: ceil(width / aspectRatio))
        }
    }

    private func audioSize(for block: AudioBlockContentV2, maxBubbleWidth: CGFloat) -> CGSize {
        let clampedDuration = min(max(block.durationSeconds ?? 12, 1), 60)
        let width = min(maxBubbleWidth, 98 + CGFloat(clampedDuration) * 1.7)
        return CGSize(width: max(118, width), height: 60)
    }

    private func senderNameSize(for sender: MessageSenderPresentationV2, maxBubbleWidth: CGFloat) -> CGSize {
        let text = sender.isBot ? "\(sender.displayName)  BOT" : sender.displayName
        let attributed = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold)
        ])
        let measured = attributed.boundingRect(
            with: CGSize(width: maxBubbleWidth, height: 16),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return CGSize(width: min(maxBubbleWidth, ceil(measured.width) + 8), height: 16)
    }

    private func statusSize(for status: MessageStatusPresentationV2) -> CGSize {
        let attributed = NSAttributedString(string: status.displayText, attributes: [
            .font: UIFont.systemFont(ofSize: 11)
        ])
        let measured = attributed.boundingRect(
            with: CGSize(width: 220, height: 16),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return CGSize(width: min(220, ceil(measured.width) + 8), height: 16)
    }

    static func avatarLayoutID(for messageID: String) -> String {
        "\(messageID)-avatar"
    }

    static func senderLayoutID(for messageID: String) -> String {
        "\(messageID)-sender"
    }

    static func statusLayoutID(for messageID: String) -> String {
        "\(messageID)-status"
    }
}

enum MessageTextFormatterV2 {
    static func attributedString(for text: String, isOutgoing: Bool, rendersMarkdown: Bool) -> NSAttributedString {
        guard rendersMarkdown else {
            return plainAttributedString(for: text, isOutgoing: isOutgoing)
        }
        return richMarkdownAttributedString(for: text, isOutgoing: isOutgoing)
    }

    private static let inlineIntentKey = NSAttributedString.Key("NSInlinePresentationIntent")
    private static let presentationIntentKey = NSAttributedString.Key("NSPresentationIntent")
    private static let inlineCodeIntent = 4
    private static let strongIntent = 2
    private static let emphasisIntent = 1

    private static func plainAttributedString(for text: String, isOutgoing: Bool) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: attributed.length)
        attributed.addAttributes(baseAttributes(isOutgoing: isOutgoing), range: range)
        return attributed
    }

    private static func richMarkdownAttributedString(for text: String, isOutgoing: Bool) -> NSAttributedString {
        let lines = text.components(separatedBy: .newlines)
        let result = NSMutableAttributedString()
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                appendSoftBreakIfNeeded(to: result, isOutgoing: isOutgoing)
                index += 1
                continue
            }

            if let codeBlock = fencedCodeBlock(from: lines, startIndex: index, isOutgoing: isOutgoing) {
                appendBlock(codeBlock.attributedString, to: result, isOutgoing: isOutgoing)
                index = codeBlock.nextIndex
                continue
            }

            if let table = tableBlock(from: lines, startIndex: index, isOutgoing: isOutgoing) {
                appendBlock(table.attributedString, to: result, isOutgoing: isOutgoing)
                index = table.nextIndex
                continue
            }

            if let heading = headingBlock(from: trimmed, isOutgoing: isOutgoing) {
                appendBlock(heading, to: result, isOutgoing: isOutgoing)
                index += 1
                continue
            }

            if isThematicBreak(trimmed) {
                appendBlock(thematicBreakBlock(isOutgoing: isOutgoing), to: result, isOutgoing: isOutgoing)
                index += 1
                continue
            }

            if let quote = quoteBlock(from: lines, startIndex: index, isOutgoing: isOutgoing) {
                appendBlock(quote.attributedString, to: result, isOutgoing: isOutgoing)
                index = quote.nextIndex
                continue
            }

            if let list = listItemBlock(from: line, isOutgoing: isOutgoing) {
                appendBlock(list, to: result, isOutgoing: isOutgoing)
                index += 1
                continue
            }

            appendBlock(inlineAttributedString(for: trimmed, style: bodyStyle(isOutgoing: isOutgoing)), to: result, isOutgoing: isOutgoing)
            index += 1
        }

        return result.length > 0 ? result : plainAttributedString(for: text, isOutgoing: isOutgoing)
    }

    private struct MarkdownTextStyle {
        let font: UIFont
        let foregroundColor: UIColor
        let linkColor: UIColor
        let inlineCodeForegroundColor: UIColor
        let inlineCodeBackgroundColor: UIColor
        let paragraphStyle: NSMutableParagraphStyle
    }

    private struct ParsedBlock {
        let attributedString: NSAttributedString
        let nextIndex: Int
    }

    private static func bodyStyle(isOutgoing: Bool) -> MarkdownTextStyle {
        style(
            font: .systemFont(ofSize: 15),
            foregroundColor: isOutgoing ? .white : .label,
            linkColor: isOutgoing ? .white : .systemBlue,
            isOutgoing: isOutgoing,
            lineSpacing: 2,
            paragraphSpacing: 3
        )
    }

    private static func headingStyle(level: Int, isOutgoing: Bool) -> MarkdownTextStyle {
        let size: CGFloat
        switch level {
        case 1: size = 22
        case 2: size = 19
        case 3: size = 17
        default: size = 16
        }
        return style(
            font: .systemFont(ofSize: size, weight: .bold),
            foregroundColor: isOutgoing ? .white : .label,
            linkColor: isOutgoing ? .white : .systemBlue,
            isOutgoing: isOutgoing,
            lineSpacing: 2,
            paragraphSpacing: level == 1 ? 8 : 6
        )
    }

    private static func quoteStyle(isOutgoing: Bool) -> MarkdownTextStyle {
        style(
            font: .systemFont(ofSize: 15),
            foregroundColor: isOutgoing ? UIColor.white.withAlphaComponent(0.86) : .secondaryLabel,
            linkColor: isOutgoing ? .white : .systemBlue,
            isOutgoing: isOutgoing,
            lineSpacing: 2,
            paragraphSpacing: 4
        )
    }

    private static func listStyle(level: Int, isOutgoing: Bool) -> MarkdownTextStyle {
        let paragraph = baseParagraph(lineSpacing: 2, paragraphSpacing: 3)
        let leading = CGFloat(level) * 18
        paragraph.firstLineHeadIndent = leading
        paragraph.headIndent = leading + 24
        paragraph.tabStops = [
            NSTextTab(textAlignment: .left, location: leading + 24)
        ]
        return MarkdownTextStyle(
            font: .systemFont(ofSize: 15),
            foregroundColor: isOutgoing ? .white : .label,
            linkColor: isOutgoing ? .white : .systemBlue,
            inlineCodeForegroundColor: isOutgoing ? .white : .label,
            inlineCodeBackgroundColor: isOutgoing ? UIColor.white.withAlphaComponent(0.16) : UIColor.systemGray5,
            paragraphStyle: paragraph
        )
    }

    private static func codeTableStyle(isOutgoing: Bool) -> MarkdownTextStyle {
        style(
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            foregroundColor: isOutgoing ? .white : .label,
            linkColor: isOutgoing ? .white : .systemBlue,
            isOutgoing: isOutgoing,
            lineSpacing: 3,
            paragraphSpacing: 6,
            lineBreakMode: .byCharWrapping
        )
    }

    private static func style(
        font: UIFont,
        foregroundColor: UIColor,
        linkColor: UIColor,
        isOutgoing: Bool,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        lineBreakMode: NSLineBreakMode = .byWordWrapping
    ) -> MarkdownTextStyle {
        let paragraph = baseParagraph(lineSpacing: lineSpacing, paragraphSpacing: paragraphSpacing, lineBreakMode: lineBreakMode)
        return MarkdownTextStyle(
            font: font,
            foregroundColor: foregroundColor,
            linkColor: linkColor,
            inlineCodeForegroundColor: isOutgoing ? .white : .label,
            inlineCodeBackgroundColor: isOutgoing ? UIColor.white.withAlphaComponent(0.16) : UIColor.systemGray5,
            paragraphStyle: paragraph
        )
    }

    private static func baseParagraph(
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        lineBreakMode: NSLineBreakMode = .byWordWrapping
    ) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacing = paragraphSpacing
        paragraph.lineBreakMode = lineBreakMode
        return paragraph
    }

    private static func inlineAttributedString(for text: String, style: MarkdownTextStyle) -> NSAttributedString {
        let attributed: NSMutableAttributedString
        if let markdown = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            attributed = NSMutableAttributedString(markdown)
        } else {
            attributed = NSMutableAttributedString(string: text)
        }

        applyInlineMarkdownAttributes(to: attributed, style: style)
        return attributed
    }

    private static func prefixedInlineAttributedString(prefix: String, text: String, style: MarkdownTextStyle, prefixColor: UIColor? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: prefix, attributes: attributes(for: style, foregroundColor: prefixColor ?? style.foregroundColor)))
        result.append(inlineAttributedString(for: text, style: style))
        return result
    }

    private static func headingBlock(from trimmedLine: String, isOutgoing: Bool) -> NSAttributedString? {
        guard let match = firstMatch(pattern: "^(#{1,6})\\s+(.+)$", in: trimmedLine) else { return nil }
        let nsLine = trimmedLine as NSString
        let level = nsLine.substring(with: match.range(at: 1)).count
        let content = nsLine.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
        return inlineAttributedString(for: content, style: headingStyle(level: level, isOutgoing: isOutgoing))
    }

    private static func quoteBlock(from lines: [String], startIndex: Int, isOutgoing: Bool) -> ParsedBlock? {
        guard startIndex < lines.count else { return nil }
        let firstTrimmed = lines[startIndex].trimmingCharacters(in: .whitespaces)
        guard firstTrimmed.hasPrefix(">") else { return nil }

        let result = NSMutableAttributedString()
        var index = startIndex
        let style = quoteStyle(isOutgoing: isOutgoing)
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            if result.length > 0 {
                result.append(NSAttributedString(string: "\n", attributes: attributes(for: style)))
            }
            let content = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            result.append(prefixedInlineAttributedString(prefix: "▏ ", text: content, style: style, prefixColor: isOutgoing ? UIColor.white.withAlphaComponent(0.7) : .systemBlue))
            index += 1
        }
        return ParsedBlock(attributedString: result, nextIndex: index)
    }

    private static func listItemBlock(from line: String, isOutgoing: Bool) -> NSAttributedString? {
        if let unordered = firstMatch(pattern: "^(\\s*)([-*+])\\s+(.+)$", in: line) {
            let nsLine = line as NSString
            let indent = indentationLevel(nsLine.substring(with: unordered.range(at: 1)))
            var content = nsLine.substring(with: unordered.range(at: 3))
            var marker = "•"
            if let checkbox = firstMatch(pattern: "^\\[( |x|X)\\]\\s+(.+)$", in: content) {
                let nsContent = content as NSString
                marker = nsContent.substring(with: checkbox.range(at: 1)).trimmingCharacters(in: .whitespaces).isEmpty ? "☐" : "☑"
                content = nsContent.substring(with: checkbox.range(at: 2))
            }
            return prefixedInlineAttributedString(prefix: "\(marker) ", text: content, style: listStyle(level: indent, isOutgoing: isOutgoing))
        }

        if let ordered = firstMatch(pattern: "^(\\s*)(\\d+)[.)]\\s+(.+)$", in: line) {
            let nsLine = line as NSString
            let indent = indentationLevel(nsLine.substring(with: ordered.range(at: 1)))
            let ordinal = nsLine.substring(with: ordered.range(at: 2))
            let content = nsLine.substring(with: ordered.range(at: 3))
            return prefixedInlineAttributedString(prefix: "\(ordinal). ", text: content, style: listStyle(level: indent, isOutgoing: isOutgoing))
        }

        return nil
    }

    private static func fencedCodeBlock(from lines: [String], startIndex: Int, isOutgoing: Bool) -> ParsedBlock? {
        guard startIndex < lines.count else { return nil }
        let opening = lines[startIndex].trimmingCharacters(in: .whitespaces)
        guard firstMatch(pattern: "^```([A-Za-z0-9_+.-]*)\\s*$", in: opening) != nil else { return nil }

        var codeLines: [String] = []
        var index = startIndex + 1
        var foundClosingFence = false
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                foundClosingFence = true
                index += 1
                break
            }
            codeLines.append(line)
            index += 1
        }

        guard foundClosingFence else {
            return nil
        }
        return ParsedBlock(
            attributedString: codeBlockAttributedString(for: codeLines.joined(separator: "\n"), isOutgoing: isOutgoing),
            nextIndex: index
        )
    }

    private static func tableBlock(from lines: [String], startIndex: Int, isOutgoing: Bool) -> ParsedBlock? {
        guard startIndex + 1 < lines.count,
              isPotentialTableRow(lines[startIndex]),
              isTableSeparator(lines[startIndex + 1])
        else {
            return nil
        }

        var rows: [[String]] = [tableCells(from: lines[startIndex])]
        var index = startIndex + 2
        while index < lines.count, isPotentialTableRow(lines[index]) {
            rows.append(tableCells(from: lines[index]))
            index += 1
        }
        guard rows.flatMap({ $0 }).contains(where: { !$0.isEmpty }) else { return nil }

        let columnCount = rows.map(\.count).max() ?? 0
        let widths = (0..<columnCount).map { column in
            rows.map { row in
                column < row.count ? row[column].count : 0
            }.max() ?? 0
        }
        let renderedRows = rows.enumerated().map { rowIndex, row in
            let cells = (0..<columnCount).map { column in
                let value = column < row.count ? row[column] : ""
                return value.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }
            let line = cells.joined(separator: "  ")
            if rowIndex == 0 {
                let separator = widths.map { String(repeating: "─", count: max($0, 3)) }.joined(separator: "  ")
                return "\(line)\n\(separator)"
            }
            return line
        }
        let tableText = renderedRows.joined(separator: "\n")
        let style = codeTableStyle(isOutgoing: isOutgoing)
        let attributed = NSMutableAttributedString(string: tableText, attributes: attributes(for: style))
        attributed.addAttribute(
            .backgroundColor,
            value: isOutgoing ? UIColor.white.withAlphaComponent(0.12) : UIColor.systemGray6,
            range: NSRange(location: 0, length: attributed.length)
        )
        return ParsedBlock(attributedString: attributed, nextIndex: index)
    }

    private static func codeBlockAttributedString(for code: String, isOutgoing: Bool) -> NSAttributedString {
        let displayCode = code.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        let attributed = NSMutableAttributedString(string: displayCode.isEmpty ? " " : displayCode)
        let style = codeTableStyle(isOutgoing: isOutgoing)
        attributed.addAttributes(attributes(for: style), range: NSRange(location: 0, length: attributed.length))
        attributed.addAttribute(
            .backgroundColor,
            value: isOutgoing ? UIColor.white.withAlphaComponent(0.16) : UIColor.systemGray5,
            range: NSRange(location: 0, length: attributed.length)
        )
        return attributed
    }

    private static func thematicBreakBlock(isOutgoing: Bool) -> NSAttributedString {
        let style = style(
            font: .systemFont(ofSize: 13, weight: .regular),
            foregroundColor: isOutgoing ? UIColor.white.withAlphaComponent(0.55) : .separator,
            linkColor: isOutgoing ? .white : .systemBlue,
            isOutgoing: isOutgoing,
            lineSpacing: 0,
            paragraphSpacing: 4
        )
        return NSAttributedString(string: "────────────", attributes: attributes(for: style))
    }

    private static func applyInlineMarkdownAttributes(to attributed: NSMutableAttributedString, style: MarkdownTextStyle) {
        guard attributed.length > 0 else { return }

        let fullRange = NSRange(location: 0, length: attributed.length)
        let runs = attributed.attributedSubstring(from: fullRange)
        attributed.addAttributes(attributes(for: style), range: fullRange)

        runs.enumerateAttributes(in: fullRange) { attributes, range, _ in
            let inlineIntent = inlineIntentValue(attributes[inlineIntentKey])
            let isInlineCode = inlineIntent & inlineCodeIntent != 0
            let font = markdownFont(forInlineIntent: inlineIntent, baseFont: style.font)
            var nextAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isInlineCode ? style.inlineCodeForegroundColor : style.foregroundColor,
                .paragraphStyle: style.paragraphStyle
            ]

            if isInlineCode {
                nextAttributes[.backgroundColor] = style.inlineCodeBackgroundColor
            }

            if let link = attributes[.link] {
                nextAttributes[.link] = link
                nextAttributes[.foregroundColor] = style.linkColor
                nextAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }

            attributed.addAttributes(nextAttributes, range: range)
        }
        attributed.removeAttribute(inlineIntentKey, range: fullRange)
        attributed.removeAttribute(presentationIntentKey, range: fullRange)
    }

    private static func attributes(for style: MarkdownTextStyle, foregroundColor: UIColor? = nil) -> [NSAttributedString.Key: Any] {
        [
            .font: style.font,
            .foregroundColor: foregroundColor ?? style.foregroundColor,
            .paragraphStyle: style.paragraphStyle
        ]
    }

    private static func baseAttributes(isOutgoing: Bool) -> [NSAttributedString.Key: Any] {
        let style = bodyStyle(isOutgoing: isOutgoing)
        return [
            .font: style.font,
            .foregroundColor: style.foregroundColor,
            .paragraphStyle: style.paragraphStyle
        ]
    }

    private static func markdownFont(forInlineIntent inlineIntent: Int, baseFont: UIFont) -> UIFont {
        if inlineIntent & inlineCodeIntent != 0 {
            return UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        }

        var traits: UIFontDescriptor.SymbolicTraits = []
        if inlineIntent & strongIntent != 0 {
            traits.insert(.traitBold)
        }
        if inlineIntent & emphasisIntent != 0 {
            traits.insert(.traitItalic)
        }
        guard !traits.isEmpty,
              let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
        else {
            return baseFont
        }
        return UIFont(descriptor: descriptor, size: baseFont.pointSize)
    }

    private static func inlineIntentValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let integer = value as? Int {
            return integer
        }
        return 0
    }

    private static func appendBlock(_ block: NSAttributedString, to attributed: NSMutableAttributedString, isOutgoing: Bool) {
        if attributed.length > 0, !attributed.string.hasSuffix("\n") {
            attributed.append(NSAttributedString(string: "\n", attributes: baseAttributes(isOutgoing: isOutgoing)))
        }
        attributed.append(block)
    }

    private static func appendSoftBreakIfNeeded(to attributed: NSMutableAttributedString, isOutgoing: Bool) {
        guard attributed.length > 0, !attributed.string.hasSuffix("\n\n") else { return }
        let separator = attributed.string.hasSuffix("\n") ? "\n" : "\n\n"
        attributed.append(NSAttributedString(string: separator, attributes: baseAttributes(isOutgoing: isOutgoing)))
    }

    private static func firstMatch(pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, range: range)
    }

    private static func isThematicBreak(_ trimmedLine: String) -> Bool {
        firstMatch(pattern: "^([-*_])(?:\\s*\\1){2,}\\s*$", in: trimmedLine) != nil
    }

    private static func indentationLevel(_ indentation: String) -> Int {
        let spaces = indentation.reduce(0) { partial, character in
            partial + (character == "\t" ? 4 : 1)
        }
        return min(4, spaces / 2)
    }

    private static func isPotentialTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && !trimmed.isEmpty
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        firstMatch(pattern: "^\\s*\\|?\\s*:?-{3,}:?\\s*(\\|\\s*:?-{3,}:?\\s*)+\\|?\\s*$", in: line) != nil
    }

    private static func tableCells(from line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") {
            trimmed.removeFirst()
        }
        if trimmed.hasSuffix("|") {
            trimmed.removeLast()
        }
        return trimmed
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

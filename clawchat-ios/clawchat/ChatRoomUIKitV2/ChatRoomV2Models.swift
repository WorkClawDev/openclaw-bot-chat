import Foundation
import UIKit

enum ChatRoomV2Fixture: String {
    case textPrependStress
    case textBenchmark
    case richMedia
}

enum ChatRoomV2FeatureFlag {
    static var isEnabled: Bool {
#if DEBUG
        true
#else
        ProcessInfo.processInfo.arguments.contains("-chatRoomV2")
#endif
    }

    static var uiTestMode: String? {
        argumentValue(after: "-uiTestMode")
    }

    static var fixture: ChatRoomV2Fixture? {
        argumentValue(after: "-fixture").flatMap(ChatRoomV2Fixture.init(rawValue:))
    }

    static var autoPrependStressCount: Int {
        argumentValue(after: "-chatRoomV2AutoPrependStress").flatMap(Int.init) ?? 0
    }

    static var autoSameIDUpdate: Bool {
        ProcessInfo.processInfo.arguments.contains("-chatRoomV2AutoSameIDUpdate")
    }

    static var autoWindowReplace: Bool {
        ProcessInfo.processInfo.arguments.contains("-chatRoomV2AutoWindowReplace")
    }

    static var autoKeyboardDuringPrepend: Bool {
        ProcessInfo.processInfo.arguments.contains("-chatRoomV2AutoKeyboardDuringPrepend")
    }

    static var autoKeyboardShowHide: Bool {
        ProcessInfo.processInfo.arguments.contains("-chatRoomV2AutoKeyboardShowHide")
    }

    static var autoRapidSnapshotBurst: Bool {
        ProcessInfo.processInfo.arguments.contains("-chatRoomV2AutoRapidSnapshotBurst")
    }

    static var autoSendFixtureImage: Bool {
        ProcessInfo.processInfo.arguments.contains("-chatRoomV2AutoSendFixtureImage")
    }

    static var showsDiagnostics: Bool {
        ProcessInfo.processInfo.arguments.contains("-chatRoomV2ShowDiagnostics")
            || uiTestMode?.hasPrefix("chatRoomV2") == true
    }

    private static func argumentValue(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex]
    }
}

struct ChatMessageV2: Identifiable, Equatable {
    let id: String
    let sequence: Int
    let isOutgoing: Bool
    let blocks: [MessageBlockContentV2]
    let sender: MessageSenderPresentationV2?
    let status: MessageStatusPresentationV2?

    var text: String {
        blocks.copyableText
    }

    init(id: String, sequence: Int, text: String, isOutgoing: Bool) {
        self.id = id
        self.sequence = sequence
        self.isOutgoing = isOutgoing
        self.blocks = MessageMarkdownBlockParserV2.blocks(messageID: id, text: text)
        self.sender = nil
        self.status = nil
    }

    init(
        id: String,
        sequence: Int,
        isOutgoing: Bool,
        blocks: [MessageBlockContentV2],
        sender: MessageSenderPresentationV2? = nil,
        status: MessageStatusPresentationV2? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.isOutgoing = isOutgoing
        self.blocks = blocks
        self.sender = sender
        self.status = status
    }

    var layoutHashValue: Int {
        var hasher = Hasher()
        hasher.combine(blocks)
        hasher.combine(sender)
        hasher.combine(status)
        return hasher.finalize()
    }
}

extension ChatMessageV2 {
    init(
        message: Message,
        currentUserID: String?,
        fallbackSequence: Int,
        preservesSourceOrder: Bool = false,
        showsSenderInfo: Bool = false,
        fallbackBotAvatarURLString: String? = nil
    ) {
        let isOutgoing = Self.normalizeIdentifier(message.senderId) == Self.normalizeIdentifier(currentUserID)
        self.init(
            id: message.id,
            sequence: preservesSourceOrder ? fallbackSequence : (message.seq ?? fallbackSequence),
            isOutgoing: isOutgoing,
            blocks: Self.blocks(for: message),
            sender: isOutgoing ? nil : Self.sender(for: message, showsSenderInfo: showsSenderInfo, fallbackBotAvatarURLString: fallbackBotAvatarURLString),
            status: Self.status(for: message)
        )
    }

    private static func blocks(for message: Message) -> [MessageBlockContentV2] {
        if normalizeIdentifier(message.content.type) == "image" {
            var blocks: [MessageBlockContentV2] = [
                .image(ImageBlockContentV2(
                    id: "\(message.id)-image-0",
                    urlString: message.content.imageURLString,
                    name: imageName(for: message),
                    aspectRatio: imageAspectRatio(for: message.content),
                    isSticker: message.content.isSticker,
                    cacheContent: message.content
                ))
            ]

            if let caption = imageCaption(for: message) {
                blocks.append(contentsOf: MessageMarkdownBlockParserV2.blocks(
                    messageID: message.id,
                    text: caption,
                    textIDPrefix: "text-caption",
                    codeIDPrefix: "code-caption"
                ))
            }
            return blocks
        }

        if message.content.isAudio {
            return [
                .audio(AudioBlockContentV2(
                    id: "\(message.id)-audio-0",
                    urlString: message.content.audioURLString,
                    durationSeconds: message.content.audioDurationSeconds,
                    durationLabel: audioDurationLabel(for: message.content),
                    cacheContent: message.content
                ))
            ]
        }

        let body = message.content.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = body?.nonEmpty ?? message.content.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? message.content.type
        return MessageMarkdownBlockParserV2.blocks(messageID: message.id, text: text)
    }

    private static func imageName(for message: Message) -> String {
        message.content.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? message.content.asset?.fileName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "图片"
    }

    private static func imageCaption(for message: Message) -> String? {
        guard let body = message.content.body?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        guard !message.content.isSticker else { return nil }
        guard normalizeIdentifier(body) != normalizeIdentifier(imageName(for: message)) else { return nil }
        return body
    }

    private static func imageAspectRatio(for content: MessageContent) -> CGFloat {
        if let asset = content.asset,
           let width = asset.width,
           let height = asset.height,
           width > 0,
           height > 0 {
            return CGFloat(width) / CGFloat(height)
        }

        if let width = content.meta?["width"]?.intValue,
           let height = content.meta?["height"]?.intValue,
           width > 0,
           height > 0 {
            return CGFloat(width) / CGFloat(height)
        }

        return content.isSticker ? 1 : 4 / 3
    }

    private static func audioDurationLabel(for content: MessageContent) -> String {
        if let seconds = content.audioDurationSeconds {
            return "\(seconds)\""
        }
        if let size = content.size ?? content.asset?.size, size > 0 {
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        return "语音"
    }

    private static func sender(
        for message: Message,
        showsSenderInfo: Bool,
        fallbackBotAvatarURLString: String?
    ) -> MessageSenderPresentationV2 {
        let isBot = normalizeIdentifier(message.from.type) == "bot"
        let name = message.from.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? (isBot ? "机器人" : "用户")
        let avatar = message.from.avatar?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? (isBot ? fallbackBotAvatarURLString?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty : nil)
        return MessageSenderPresentationV2(
            displayName: name,
            avatarURLString: avatar,
            isBot: isBot,
            showsName: showsSenderInfo
        )
    }

    private static func status(for message: Message) -> MessageStatusPresentationV2? {
        let timestamp = message.displayDate.map(statusFormatter.string(from:))
        guard timestamp != nil || message.pending || message.failed else { return nil }
        return MessageStatusPresentationV2(timestampText: timestamp, isPending: message.pending, isFailed: message.failed)
    }

    private static func normalizeIdentifier(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private static let statusFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

enum MessageBlockContentV2: Hashable {
    case text(TextBlockContentV2)
    case code(CodeBlockContentV2)
    case table(TableBlockContentV2)
    case image(ImageBlockContentV2)
    case audio(AudioBlockContentV2)

    var id: String {
        switch self {
        case .text(let block):
            block.id
        case .code(let block):
            block.id
        case .table(let block):
            block.id
        case .image(let block):
            block.id
        case .audio(let block):
            block.id
        }
    }

    var copyableText: String? {
        switch self {
        case .text(let block):
            block.text
        case .code(let block):
            block.code
        case .table(let block):
            block.copyableText
        case .image, .audio:
            nil
        }
    }
}

struct TextBlockContentV2: Hashable {
    let id: String
    let text: String
    let isMarkdown: Bool

    static func shouldRenderMarkdown(_ text: String) -> Bool {
        text.rangeOfCharacter(from: CharacterSet(charactersIn: "`*_#[]()>!\n")) != nil
    }
}

struct CodeBlockContentV2: Hashable {
    let id: String
    let code: String
    let language: String?
}

struct TableBlockContentV2: Hashable {
    let id: String
    let rows: [[String]]

    var header: [String] {
        rows.first ?? []
    }

    var bodyRows: [[String]] {
        rows.count > 1 ? Array(rows.dropFirst()) : []
    }

    var columnCount: Int {
        rows.map(\.count).max() ?? 0
    }

    var copyableText: String {
        rows.map { row in
            row.joined(separator: "\t")
        }.joined(separator: "\n")
    }
}

struct ImageBlockContentV2: Hashable {
    let id: String
    let urlString: String?
    let name: String
    let aspectRatio: CGFloat
    let isSticker: Bool
    let cacheContent: MessageContent

    init(
        id: String,
        urlString: String?,
        name: String,
        aspectRatio: CGFloat,
        isSticker: Bool,
        cacheContent: MessageContent? = nil
    ) {
        self.id = id
        self.urlString = urlString
        self.name = name
        self.aspectRatio = aspectRatio
        self.isSticker = isSticker
        self.cacheContent = cacheContent ?? MessageContent(
            type: "image",
            body: nil,
            url: urlString,
            name: name,
            size: nil,
            meta: nil
        )
    }

    static func == (lhs: ImageBlockContentV2, rhs: ImageBlockContentV2) -> Bool {
        lhs.id == rhs.id
            && lhs.urlString == rhs.urlString
            && lhs.name == rhs.name
            && lhs.aspectRatio == rhs.aspectRatio
            && lhs.isSticker == rhs.isSticker
            && lhs.cacheContent.mediaCacheSignatureV2 == rhs.cacheContent.mediaCacheSignatureV2
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(urlString)
        hasher.combine(name)
        hasher.combine(aspectRatio)
        hasher.combine(isSticker)
        hasher.combine(cacheContent.mediaCacheSignatureV2)
    }
}

struct AudioBlockContentV2: Hashable {
    let id: String
    let urlString: String?
    let durationSeconds: Int?
    let durationLabel: String
    let cacheContent: MessageContent

    init(
        id: String,
        urlString: String?,
        durationSeconds: Int?,
        durationLabel: String,
        cacheContent: MessageContent? = nil
    ) {
        self.id = id
        self.urlString = urlString
        self.durationSeconds = durationSeconds
        self.durationLabel = durationLabel
        self.cacheContent = cacheContent ?? MessageContent(
            type: "audio",
            body: nil,
            url: urlString,
            name: nil,
            size: nil,
            meta: nil
        )
    }

    static func == (lhs: AudioBlockContentV2, rhs: AudioBlockContentV2) -> Bool {
        lhs.id == rhs.id
            && lhs.urlString == rhs.urlString
            && lhs.durationSeconds == rhs.durationSeconds
            && lhs.durationLabel == rhs.durationLabel
            && lhs.cacheContent.mediaCacheSignatureV2 == rhs.cacheContent.mediaCacheSignatureV2
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(urlString)
        hasher.combine(durationSeconds)
        hasher.combine(durationLabel)
        hasher.combine(cacheContent.mediaCacheSignatureV2)
    }
}

extension MessageContent {
    var mediaCacheSignatureV2: String {
        [
            type,
            asset?.id,
            asset?.objectKey,
            asset?.preferredMediaURLString,
            mediaURLString,
            name,
            size.map(String.init)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "|")
    }
}

struct MessageSenderPresentationV2: Hashable {
    let displayName: String
    let avatarURLString: String?
    let isBot: Bool
    let showsName: Bool
}

struct MessageStatusPresentationV2: Hashable {
    let timestampText: String?
    let isPending: Bool
    let isFailed: Bool

    init(timestampText: String?, isPending: Bool, isFailed: Bool = false) {
        self.timestampText = timestampText
        self.isPending = isPending
        self.isFailed = isFailed
    }

    var displayText: String {
        let pieces = [timestampText, isFailed ? "Failed" : (isPending ? "Sending" : nil)].compactMap { $0 }
        return pieces.joined(separator: " · ")
    }
}

private extension Array where Element == MessageBlockContentV2 {
    var copyableText: String {
        compactMap(\.copyableText).joined(separator: "\n")
    }
}

enum MessageMarkdownBlockParserV2 {
    static func blocks(
        messageID: String,
        text: String,
        textIDPrefix: String = "text",
        codeIDPrefix: String = "code",
        tableIDPrefix: String = "table"
    ) -> [MessageBlockContentV2] {
        guard TextBlockContentV2.shouldRenderMarkdown(text) else {
            return [.text(TextBlockContentV2(id: "\(messageID)-\(textIDPrefix)-0", text: text, isMarkdown: false))]
        }

        let segments = fencedCodeSegments(in: text)
        let containsStructuredBlock = segments.contains { segment in
            if case .code = segment { return true }
            return false
        } || segments.contains { segment in
            if case .inline(let value) = segment {
                return inlineSegments(in: value).contains { inlineSegment in
                    if case .table = inlineSegment { return true }
                    return false
                }
            }
            return false
        }
        guard containsStructuredBlock else {
            return [.text(TextBlockContentV2(id: "\(messageID)-\(textIDPrefix)-0", text: text, isMarkdown: true))]
        }

        var blocks: [MessageBlockContentV2] = []
        var textIndex = 0
        var codeIndex = 0
        var tableIndex = 0
        for segment in segments {
            switch segment {
            case .inline(let value):
                for inlineSegment in inlineSegments(in: value) {
                    switch inlineSegment {
                    case .text(let text):
                        let normalized = text.trimmingCharacters(in: .newlines)
                        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        blocks.append(.text(TextBlockContentV2(
                            id: "\(messageID)-\(textIDPrefix)-\(textIndex)",
                            text: normalized,
                            isMarkdown: true
                        )))
                        textIndex += 1
                    case .table(let rows):
                        blocks.append(.table(TableBlockContentV2(
                            id: "\(messageID)-\(tableIDPrefix)-\(tableIndex)",
                            rows: rows
                        )))
                        tableIndex += 1
                    }
                }
            case .code(let language, let code):
                let displayCode = code.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
                blocks.append(.code(CodeBlockContentV2(
                    id: "\(messageID)-\(codeIDPrefix)-\(codeIndex)",
                    code: displayCode.isEmpty ? " " : displayCode,
                    language: language
                )))
                codeIndex += 1
            }
        }
        return blocks.isEmpty
            ? [.text(TextBlockContentV2(id: "\(messageID)-\(textIDPrefix)-0", text: text, isMarkdown: true))]
            : blocks
    }

    private enum Segment {
        case inline(String)
        case code(language: String?, code: String)
    }

    private enum InlineSegment {
        case text(String)
        case table([[String]])
    }

    private static func fencedCodeSegments(in text: String) -> [Segment] {
        let pattern = "```([A-Za-z0-9_+.-]*)[ \\t]*\\n?([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.inline(text)]
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else {
            return [.inline(text)]
        }

        var segments: [Segment] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                segments.append(.inline(nsText.substring(with: NSRange(
                    location: cursor,
                    length: match.range.location - cursor
                ))))
            }

            let languageRange = match.range(at: 1)
            let codeRange = match.range(at: 2)
            let language = languageRange.location == NSNotFound
                ? nil
                : nsText.substring(with: languageRange).trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            let code = codeRange.location == NSNotFound ? "" : nsText.substring(with: codeRange)
            segments.append(.code(language: language, code: code))
            cursor = match.range.location + match.range.length
        }

        if cursor < nsText.length {
            segments.append(.inline(nsText.substring(with: NSRange(
                location: cursor,
                length: nsText.length - cursor
            ))))
        }

        return segments
    }

    private static func inlineSegments(in text: String) -> [InlineSegment] {
        let lines = text.components(separatedBy: .newlines)
        var segments: [InlineSegment] = []
        var pendingText: [String] = []
        var index = 0

        func flushText() {
            guard !pendingText.isEmpty else { return }
            segments.append(.text(pendingText.joined(separator: "\n")))
            pendingText.removeAll()
        }

        while index < lines.count {
            if let table = tableRows(from: lines, startIndex: index) {
                flushText()
                segments.append(.table(table.rows))
                index = table.nextIndex
            } else {
                pendingText.append(lines[index])
                index += 1
            }
        }

        flushText()
        return segments
    }

    private static func tableRows(from lines: [String], startIndex: Int) -> (rows: [[String]], nextIndex: Int)? {
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

        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0,
              rows.flatMap({ $0 }).contains(where: { !$0.isEmpty })
        else {
            return nil
        }

        let normalizedRows = rows.map { row in
            row + Array(repeating: "", count: max(0, columnCount - row.count))
        }
        return (normalizedRows, index)
    }

    private static func isPotentialTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && !trimmed.isEmpty
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let pattern = "^\\s*\\|?\\s*:?-{3,}:?\\s*(\\|\\s*:?-{3,}:?\\s*)+\\|?\\s*$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
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

struct BlockLayoutV2: Equatable {
    let id: String
    let frame: CGRect
}

struct MessageLayoutV2: Equatable {
    let itemSize: CGSize
    let blockLayouts: [BlockLayoutV2]
}

struct RenderedMessageV2: Identifiable, Equatable {
    let id: String
    let sequence: Int
    let isOutgoing: Bool
    let blocks: [MessageBlockContentV2]
    let sender: MessageSenderPresentationV2?
    let status: MessageStatusPresentationV2?
    let layout: MessageLayoutV2

    var text: String {
        blocks.copyableText
    }

    init(id: String, sequence: Int, text: String, isOutgoing: Bool, layout: MessageLayoutV2) {
        self.id = id
        self.sequence = sequence
        self.isOutgoing = isOutgoing
        self.blocks = [
            .text(TextBlockContentV2(
                id: "\(id)-text-0",
                text: text,
                isMarkdown: TextBlockContentV2.shouldRenderMarkdown(text)
            ))
        ]
        self.sender = nil
        self.status = nil
        self.layout = layout
    }

    init(
        id: String,
        sequence: Int,
        isOutgoing: Bool,
        blocks: [MessageBlockContentV2],
        sender: MessageSenderPresentationV2? = nil,
        status: MessageStatusPresentationV2? = nil,
        layout: MessageLayoutV2
    ) {
        self.id = id
        self.sequence = sequence
        self.isOutgoing = isOutgoing
        self.blocks = blocks
        self.sender = sender
        self.status = status
        self.layout = layout
    }
}

struct VisibleMessageAnchorV2: Equatable {
    let messageID: String
    let offsetFromVisibleTop: CGFloat
}

enum ChatRoomV2FixtureFactory {
    static func initialTextMessages(count: Int = 60, newestSequence: Int = 1000) -> [ChatMessageV2] {
        let oldestSequence = newestSequence - count + 1
        return (oldestSequence...newestSequence).map { sequence in
            message(sequence: sequence)
        }
    }

    static func historyPage(before sequence: Int, count: Int = 30) -> [ChatMessageV2] {
        guard sequence > 1 else { return [] }
        let end = sequence - 1
        let start = max(1, end - count + 1)
        guard start <= end else { return [] }
        return (start...end).map { sequence in
            message(sequence: sequence)
        }
    }

    static func benchmarkMessages(count: Int = 1000) -> [ChatMessageV2] {
        (1...count).map { sequence in
            message(sequence: sequence)
        }
    }

    static func richMediaMessages() -> [ChatMessageV2] {
        [
            ChatMessageV2(
                id: "v2-rich-markdown",
                sequence: 1,
                isOutgoing: false,
                blocks: [
                    .text(TextBlockContentV2(
                        id: "v2-rich-markdown-text-0",
                        text: """
                        # Markdown torture

                        **Bold**, *italic*, ***both***, `inline code`, and [a link](https://example.com).

                        - stable native geometry
                          - nested bullet
                        1. ordered item
                        2. second item
                        - [x] checked task
                        - [ ] unchecked task

                        > Quoted text should keep its own visual treatment.
                        """,
                        isMarkdown: true
                    )),
                    .table(TableBlockContentV2(
                        id: "v2-rich-markdown-table-0",
                        rows: [
                            ["Format", "Status", "Notes"],
                            ["Heading", "Visible", "Large bold title"],
                            ["Table", "Native", "Horizontally scrollable"],
                            ["Code", "Highlighted", "Stable geometry"]
                        ]
                    )),
                    .code(CodeBlockContentV2(
                        id: "v2-rich-markdown-code-0",
                        code: "let layout = CollectionViewChatLayout()\nlayout.keepContentAtBottomOfVisibleArea = true\nlet longLine = \"This long Swift line should remain horizontally scrollable instead of being broken apart by character wrapping.\"",
                        language: "swift"
                    )),
                    .code(CodeBlockContentV2(
                        id: "v2-rich-markdown-code-1",
                        code: "{\n  \"markdown\": true,\n  \"codeHighlight\": \"required\",\n  \"stableGeometry\": true\n}",
                        language: "json"
                    ))
                ],
                sender: MessageSenderPresentationV2(
                    displayName: "Fixture Bot",
                    avatarURLString: nil,
                    isBot: true,
                    showsName: true
                ),
                status: MessageStatusPresentationV2(timestampText: "09:30", isPending: false)
            ),
            ChatMessageV2(
                id: "v2-rich-image",
                sequence: 2,
                isOutgoing: true,
                blocks: [
                    .image(ImageBlockContentV2(
                        id: "v2-rich-image-image-0",
                        urlString: nil,
                        name: "fixture-image.jpg",
                        aspectRatio: 4 / 3,
                        isSticker: false
                    )),
                    .text(TextBlockContentV2(
                        id: "v2-rich-image-text-caption",
                        text: "Image block keeps this fixed geometry before loading.",
                        isMarkdown: false
                    ))
                ],
                status: MessageStatusPresentationV2(timestampText: "09:31", isPending: true)
            ),
            ChatMessageV2(
                id: "v2-rich-audio",
                sequence: 3,
                isOutgoing: false,
                blocks: [
                    .audio(AudioBlockContentV2(
                        id: "v2-rich-audio-audio-0",
                        urlString: nil,
                        durationSeconds: 12,
                        durationLabel: "12\""
                    ))
                ],
                sender: MessageSenderPresentationV2(
                    displayName: "Fixture User",
                    avatarURLString: nil,
                    isBot: false,
                    showsName: true
                ),
                status: MessageStatusPresentationV2(timestampText: "09:32", isPending: false)
            )
        ]
    }

    private static func message(sequence: Int) -> ChatMessageV2 {
        let variants = [
            "Short deterministic text message.",
            "This is a slightly longer text-only message used to verify fixed geometry during rapid scrolling.",
            "UIKit V2 keeps the external item size stable before insertion, so the collection view never waits for post-insertion measuring.",
            "A long plain text row repeats enough content to wrap across multiple lines while staying fully deterministic. The renderer measures it once before the item reaches the collection view."
        ]
        let text = "#\(sequence) " + variants[sequence % variants.count]
        return ChatMessageV2(
            id: "v2-message-\(sequence)",
            sequence: sequence,
            text: text,
            isOutgoing: sequence.isMultiple(of: 4)
        )
    }
}

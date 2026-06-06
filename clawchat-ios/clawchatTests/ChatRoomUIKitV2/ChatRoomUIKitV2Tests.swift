import Foundation
import Testing
import UIKit
@testable import clawchat

@MainActor
struct ChatRoomUIKitV2Tests {
    @Test func storeSortsAndDeduplicatesStableMessages() {
        let layout = MessageLayoutV2(itemSize: CGSize(width: 320, height: 44), blockLayouts: [])
        let messages = [
            RenderedMessageV2(id: "m3", sequence: 3, text: "three", isOutgoing: false, layout: layout),
            RenderedMessageV2(id: "m1", sequence: 1, text: "one", isOutgoing: false, layout: layout),
            RenderedMessageV2(id: "m3", sequence: 3, text: "dupe", isOutgoing: true, layout: layout),
            RenderedMessageV2(id: "m2", sequence: 2, text: "two", isOutgoing: true, layout: layout)
        ]

        let store = ChatMessageStoreV2()
        store.initialLoad(messages)

        #expect(store.messages.map(\.id) == ["m1", "m2", "m3"])
        #expect(store.earliestSequence == 1)
    }

    @Test func rendererPrecomputesExactTextGeometryBeforeInsertion() {
        let renderer = MessageRenderCoordinatorV2()
        let raw = ChatMessageV2(
            id: "message-1",
            sequence: 1,
            text: "A long text message that should wrap but still receive a deterministic precomputed item size.",
            isOutgoing: false
        )

        let rendered = renderer.render(raw, containerWidth: 390, traitCollection: UITraitCollection(displayScale: 3))

        #expect(rendered.layout.itemSize.width == 390)
        #expect(rendered.layout.itemSize.height > 40)
        #expect(rendered.layout.blockLayouts.count == 1)
        #expect(rendered.layout.blockLayouts[0].id == "message-1-text-0")
    }

    @Test func rendererPrecomputesMarkdownImageAndAudioGeometryBeforeInsertion() {
        let renderer = MessageRenderCoordinatorV2()
        let raw = ChatMessageV2(
            id: "message-media",
            sequence: 12,
            isOutgoing: false,
            blocks: [
                .text(TextBlockContentV2(id: "message-media-text-0", text: "**Markdown** with `code`", isMarkdown: true)),
                .image(ImageBlockContentV2(id: "message-media-image-0", urlString: "https://example.test/image.jpg", name: "image.jpg", aspectRatio: 4 / 3, isSticker: false)),
                .audio(AudioBlockContentV2(id: "message-media-audio-0", urlString: "https://example.test/audio.m4a", durationSeconds: 8, durationLabel: "8\""))
            ],
            sender: MessageSenderPresentationV2(displayName: "Test Bot", avatarURLString: nil, isBot: true, showsName: true),
            status: MessageStatusPresentationV2(timestampText: "10:24", isPending: true)
        )

        let rendered = renderer.render(raw, containerWidth: 390, traitCollection: UITraitCollection(displayScale: 3))

        #expect(rendered.layout.itemSize.width == 390)
        #expect(rendered.layout.blockLayouts.map(\.id) == [
            "message-media-sender",
            "message-media-text-0",
            "message-media-image-0",
            "message-media-audio-0",
            "message-media-status",
            "message-media-avatar"
        ])
        #expect(rendered.layout.blockLayouts.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })
        #expect(rendered.layout.blockLayouts[2].frame.height > rendered.layout.blockLayouts[1].frame.height)
    }

    @Test func renderedMediaBlocksPreserveOriginalCacheIdentity() {
        let content = MessageContent(
            type: "image",
            body: "Local image",
            url: "https://example.test/api/v1/assets/image/public-url",
            name: "local.jpg",
            size: 12_345,
            meta: [
                "asset": AnyCodable([
                    "id": AnyCodable("asset-local-1"),
                    "object_key": AnyCodable("uploads/local.jpg"),
                    "mime_type": AnyCodable("image/jpeg"),
                    "width": AnyCodable(640),
                    "height": AnyCodable(480)
                ])
            ]
        )
        let message = Message(from: RealtimeMessagePayload(
            id: "message-local-image",
            topic: "topic",
            conversationId: "conversation",
            timestamp: 1_800_000_000,
            from: MessagePeerPayload(type: "bot", id: "bot", name: "Bot", avatar: nil),
            to: MessagePeerPayload(type: "user", id: "user", name: "User", avatar: nil),
            content: RealtimeContentPayload(
                type: content.type,
                body: content.body,
                url: content.url,
                name: content.name,
                size: content.size,
                meta: content.meta
            ),
            seq: 22
        ))

        let chatMessage = ChatMessageV2(message: message, currentUserID: "user", fallbackSequence: 22)

        guard case .image(let imageBlock) = chatMessage.blocks.first else {
            Issue.record("Expected image message to render as an image block")
            return
        }
        #expect(imageBlock.cacheContent.asset?.id == "asset-local-1")
        #expect(imageBlock.cacheContent.asset?.objectKey == "uploads/local.jpg")
        #expect(imageBlock.cacheContent.mediaCacheSignatureV2.contains("asset-local-1"))
    }

    @Test func rendererSplitsFencedCodeIntoNativePrecomputedBlock() {
        let renderer = MessageRenderCoordinatorV2()
        let raw = ChatMessageV2(
            id: "message-code",
            sequence: 13,
            text: "Here is code:\n\n```swift\nlet value = 42\nprint(value)\n```\nDone.",
            isOutgoing: false
        )

        let rendered = renderer.render(raw, containerWidth: 390, traitCollection: UITraitCollection(displayScale: 3))

        #expect(rendered.blocks.map(\.id) == [
            "message-code-text-0",
            "message-code-code-0",
            "message-code-text-1"
        ])
        #expect(rendered.layout.blockLayouts.map(\.id) == rendered.blocks.map(\.id))
        guard case .code(let codeBlock) = rendered.blocks[1] else {
            Issue.record("Expected fenced code to render as a native code block")
            return
        }
        #expect(codeBlock.language == "swift")
        #expect(codeBlock.code.contains("print(value)"))
        let codeLayout = rendered.layout.blockLayouts[1].frame
        #expect(codeLayout.width <= 300)
        #expect(codeLayout.height >= 48)
    }

    @Test func rendererSplitsMarkdownTableIntoNativePrecomputedBlock() {
        let renderer = MessageRenderCoordinatorV2()
        let raw = ChatMessageV2(
            id: "message-table",
            sequence: 15,
            text: """
            Here is a table:

            | Feature | Status | Notes |
            | --- | --- | --- |
            | Markdown | Native | Matches chat app table style |
            | Code | Highlighted | Stable geometry |

            Done.
            """,
            isOutgoing: false
        )

        let rendered = renderer.render(raw, containerWidth: 390, traitCollection: UITraitCollection(displayScale: 3))

        #expect(rendered.blocks.map(\.id) == [
            "message-table-text-0",
            "message-table-table-0",
            "message-table-text-1"
        ])
        guard case .table(let tableBlock) = rendered.blocks[1] else {
            Issue.record("Expected Markdown table to render as a native table block")
            return
        }
        #expect(tableBlock.rows[0] == ["Feature", "Status", "Notes"])
        #expect(tableBlock.rows[1][0] == "Markdown")
        let tableLayout = rendered.layout.blockLayouts[1].frame
        #expect(tableLayout.width <= 300)
        #expect(tableLayout.height == ChatTableLayoutMetricsV2.metrics(for: tableBlock).contentHeight)
        #expect(ChatTableLayoutMetricsV2.metrics(for: tableBlock).contentWidth > tableLayout.width)
    }

    @Test func markdownFormatterPreservesInlineStylesAndCodeBlockSpacing() {
        let attributed = MessageTextFormatterV2.attributedString(
            for: "**Bold** and *italic* with `code`\n- first item\n- second item\n\n```swift\nlet x = 1\n```\n[link](https://example.com)",
            isOutgoing: false,
            rendersMarkdown: true
        )
        let string = attributed.string as NSString

        #expect(!attributed.string.contains("codelet x"))
        #expect(attributed.string.contains("• second item\n\nlet x = 1"))
        #expect(attributed.string.contains("• first item"))
        #expect(attributed.string.contains("• second item"))
        #expect(!attributed.string.contains("first itemsecond item"))

        let boldFont = attributed.attribute(.font, at: string.range(of: "Bold").location, effectiveRange: nil) as? UIFont
        #expect(boldFont?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)

        let italicFont = attributed.attribute(.font, at: string.range(of: "italic").location, effectiveRange: nil) as? UIFont
        #expect(italicFont?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true)

        let inlineCodeRange = string.range(of: "code")
        let inlineCodeFont = attributed.attribute(.font, at: inlineCodeRange.location, effectiveRange: nil) as? UIFont
        #expect(inlineCodeFont?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true)
        #expect(attributed.attribute(.backgroundColor, at: inlineCodeRange.location, effectiveRange: nil) is UIColor)

        let codeBlockRange = string.range(of: "let x = 1")
        let codeBlockFont = attributed.attribute(.font, at: codeBlockRange.location, effectiveRange: nil) as? UIFont
        #expect(codeBlockFont?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true)
        #expect(attributed.attribute(.backgroundColor, at: codeBlockRange.location, effectiveRange: nil) is UIColor)

        let linkRange = string.range(of: "link")
        #expect(attributed.attribute(.link, at: linkRange.location, effectiveRange: nil) != nil)
    }

    @Test func markdownFormatterRendersCommonChatGPTBlocks() {
        let attributed = MessageTextFormatterV2.attributedString(
            for: """
            # Heading One

            Paragraph with ***strong italic*** and `inline code`.

            1. ordered item
            2. second ordered item
            - [x] checked task
              - nested bullet

            > quoted reply

            | Key | Value |
            | --- | --- |
            | code | highlighted |
            """,
            isOutgoing: false,
            rendersMarkdown: true
        )
        let nsString = attributed.string as NSString

        #expect(!attributed.string.contains("# Heading"))
        #expect(attributed.string.contains("Heading One"))
        #expect(attributed.string.contains("1. ordered item"))
        #expect(attributed.string.contains("2. second ordered item"))
        #expect(attributed.string.contains("☑ checked task"))
        #expect(attributed.string.contains("• nested bullet"))
        #expect(attributed.string.contains("▏ quoted reply"))
        #expect(attributed.string.contains("Key"))
        #expect(attributed.string.contains("Value"))
        #expect(!attributed.string.contains("| --- |"))

        let headingFont = attributed.attribute(.font, at: nsString.range(of: "Heading One").location, effectiveRange: nil) as? UIFont
        let paragraphFont = attributed.attribute(.font, at: nsString.range(of: "Paragraph").location, effectiveRange: nil) as? UIFont
        #expect((headingFont?.pointSize ?? 0) > (paragraphFont?.pointSize ?? 0))
        #expect(headingFont?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)

        let inlineCodeRange = nsString.range(of: "inline code")
        let inlineCodeFont = attributed.attribute(.font, at: inlineCodeRange.location, effectiveRange: nil) as? UIFont
        #expect(inlineCodeFont?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true)
        #expect(attributed.attribute(.backgroundColor, at: inlineCodeRange.location, effectiveRange: nil) is UIColor)

        let tableFont = attributed.attribute(.font, at: nsString.range(of: "highlighted").location, effectiveRange: nil) as? UIFont
        #expect(tableFont?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true)
    }

    @Test func codeHighlighterAppliesTokenColorsWithoutChangingText() async {
        let code = "let value = 42\nprint(\"value\", value)"
        let attributed = await ChatCodeSyntaxHighlighterV2.highlightedAttributedString(
            for: code,
            language: "swift",
            isOutgoing: false,
            userInterfaceStyle: .light
        )

        #expect(attributed.string == code)
        var colors = Set<String>()
        attributed.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let value {
                colors.insert(String(describing: value))
            }
        }
        #expect(colors.count >= 2)
    }

    @Test func rendererKeepsLongCodeLineHorizontallyScrollableWithoutGrowingHeight() {
        let renderer = MessageRenderCoordinatorV2()
        let longLine = "let response = " + String(repeating: "\"chunk\" + ", count: 18) + "\"done\""
        let raw = ChatMessageV2(
            id: "message-long-code",
            sequence: 14,
            text: "```swift\n\(longLine)\n```",
            isOutgoing: false
        )

        let rendered = renderer.render(raw, containerWidth: 390, traitCollection: UITraitCollection(displayScale: 3))

        guard case .code(let codeBlock) = rendered.blocks.first else {
            Issue.record("Expected a native code block")
            return
        }
        let codeLayout = rendered.layout.blockLayouts[0].frame
        #expect(codeLayout.width <= 300)
        #expect(ChatCodeSyntaxHighlighterV2.contentWidth(for: codeBlock.code) > codeLayout.width - 24)
        #expect(codeLayout.height < 120)
    }

    @Test func imageBlockProvidesDiskCacheCompatibleContent() {
        let block = ImageBlockContentV2(
            id: "image-block-1",
            urlString: "https://example.test/media/photo.png",
            name: "photo.png",
            aspectRatio: 4 / 3,
            isSticker: false
        )

        let content = block.cacheContent

        #expect(content.type == "image")
        #expect(content.url == "https://example.test/media/photo.png")
        #expect(content.name == "photo.png")
        #expect(content.imageURLString == "https://example.test/media/photo.png")
    }

    @Test func localImageStoreCanCacheV2ImageBlockContent() {
        let store = LocalImageStore()
        let block = ImageBlockContentV2(
            id: "image-block-cache-test",
            urlString: "https://example.test/media/cached-v2-image.png",
            name: "cached-v2-image.png",
            aspectRatio: 1,
            isSticker: false
        )

        let didCache = store.cacheImageData(
            Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            for: block.cacheContent,
            fallbackIdentifier: block.id
        )

        #expect(didCache != nil)
        #expect(store.cachedFileURL(for: block.cacheContent, fallbackIdentifier: block.id) != nil)
    }

    @Test func prependingHistoryPreservesOrderingWithoutReplacingExistingMessages() {
        let renderer = MessageRenderCoordinatorV2()
        let store = ChatMessageStoreV2()
        let initial = renderer.renderPage(
            ChatRoomV2FixtureFactory.initialTextMessages(count: 3, newestSequence: 10),
            containerWidth: 390,
            traitCollection: UITraitCollection(displayScale: 3)
        )
        let older = renderer.renderPage(
            ChatRoomV2FixtureFactory.historyPage(before: 8, count: 3),
            containerWidth: 390,
            traitCollection: UITraitCollection(displayScale: 3)
        )

        store.initialLoad(initial)
        store.prependHistory(older)

        #expect(store.messages.map(\.sequence) == [5, 6, 7, 8, 9, 10])
    }

    @Test func mutationCoordinatorSerializesNestedOperations() {
        let coordinator = ChatMutationCoordinatorV2()
        var events: [String] = []
        var finishFirst: (() -> Void)?

        coordinator.enqueue { finish in
            events.append("first-start")
            finishFirst = finish
        }
        coordinator.enqueue { finish in
            events.append("second-start")
            finish()
        }

        #expect(events == ["first-start"])
        #expect(coordinator.isBusy)
        #expect(coordinator.pendingCount == 1)

        finishFirst?()

        #expect(events == ["first-start", "second-start"])
        #expect(!coordinator.isBusy)
        #expect(coordinator.pendingCount == 0)
    }

    @Test func audioCoordinatorPublishesSinglePlaybackState() {
        let coordinator = ChatAudioPlaybackCoordinatorV2()
        var states: [ChatAudioPlaybackStateV2] = []
        let observer = coordinator.addObserver { states.append($0) }

        coordinator.toggle(block: AudioBlockContentV2(
            id: "audio-without-url",
            urlString: nil,
            durationSeconds: nil,
            durationLabel: "语音"
        ))
        coordinator.removeObserver(observer)

        #expect(states.first == .idle)
        #expect(states.last == ChatAudioPlaybackStateV2(
            playingBlockID: nil,
            loadingBlockID: nil,
            failedBlockID: "audio-without-url"
        ))
        #expect(coordinator.state.failedBlockID == "audio-without-url")
        #expect(coordinator.state.playingBlockID == nil)
        #expect(coordinator.state.loadingBlockID == nil)
    }

    @Test func optimisticMessagesUseSequenceAfterRemoteHistory() {
        let remote = message(id: "remote-100", sequence: 100, body: "remote")
        let optimistic = message(id: "pending", sequence: nil, body: "pending", pending: true)
        let maxRemoteSequence = [remote, optimistic].compactMap(\.seq).max() ?? 0
        var optimisticSequenceOffset = 0

        let rendered = [remote, optimistic].enumerated().map { index, message in
            let fallbackSequence: Int
            if message.seq == nil {
                optimisticSequenceOffset += 1
                fallbackSequence = maxRemoteSequence + optimisticSequenceOffset
            } else {
                fallbackSequence = index
            }
            return ChatMessageV2(message: message, currentUserID: "user", fallbackSequence: fallbackSequence)
        }

        #expect(rendered.map(\.sequence) == [100, 101])
        #expect(rendered.last?.id == "pending")
    }

    private func message(id: String, sequence: Int?, body: String, pending: Bool = false) -> Message {
        Message(
            from: RealtimeMessagePayload(
                id: id,
                topic: "chat/dm/user/user/bot/bot",
                conversationId: "chat/dm/user/user/bot/bot",
                timestamp: Int64(1_800_000_000 + (sequence ?? 101)),
                from: MessagePeerPayload(type: "user", id: "user", name: "User", avatar: nil),
                to: MessagePeerPayload(type: "bot", id: "bot", name: "Bot", avatar: nil),
                content: RealtimeContentPayload(type: "text", body: body, url: nil, name: nil, size: nil, meta: nil),
                seq: sequence.map(Int64.init)
            ),
            pending: pending
        )
    }
}

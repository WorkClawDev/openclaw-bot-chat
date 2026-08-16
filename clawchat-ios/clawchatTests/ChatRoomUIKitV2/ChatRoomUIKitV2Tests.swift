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

    @Test func storeNormalizesMessagesBeforeDiffingPendingUpdates() {
        let layout = MessageLayoutV2(itemSize: CGSize(width: 320, height: 44), blockLayouts: [])
        let messages = [
            RenderedMessageV2(id: "confirmed", sequence: 7, text: "confirmed", isOutgoing: false, layout: layout),
            RenderedMessageV2(id: "pending-now-confirmed", sequence: 6, text: "confirmed pending", isOutgoing: true, layout: layout),
            RenderedMessageV2(id: "older", sequence: 5, text: "older", isOutgoing: false, layout: layout)
        ]

        let normalized = ChatMessageStoreV2.normalized(messages)

        #expect(normalized.map(\.id) == ["older", "pending-now-confirmed", "confirmed"])
    }

    @Test func pendingStatusUsesSubduedLocalizedText() {
        let status = MessageStatusPresentationV2(timestampText: "09:31", isPending: true)

        #expect(status.displayText == "09:31 · \(L10n.t("发送中", "Sending"))")
    }

    @Test func failedStatusUsesStableSubduedText() {
        let status = MessageStatusPresentationV2(timestampText: "09:31", isPending: false, isFailed: true)

        #expect(status.displayText == "09:31 · \(L10n.t("发送失败", "Failed"))")
    }

    @Test func markdownDetectionKeepsOrdinaryChatTextOnPlainFastPath() {
        #expect(!TextBlockContentV2.shouldRenderMarkdown("#995 Plain history row."))
        #expect(!TextBlockContentV2.shouldRenderMarkdown("Looks good! (done)"))
        #expect(!TextBlockContentV2.shouldRenderMarkdown("line one\nline two"))
        #expect(!TextBlockContentV2.shouldRenderMarkdown("array[index]"))
    }

    @Test func markdownDetectionRecognizesSupportedSyntax() {
        let markdownSamples = [
            "# Heading",
            "**bold**",
            "*italic*",
            "`inline code`",
            "[link](https://example.com)",
            "<https://example.com>",
            "- list item",
            "*\tlist item",
            "1. ordered item",
            "> quote",
            "```swift\nlet value = 1\n```",
            "| A | B |\n| --- | --- |"
        ]

        for sample in markdownSamples {
            #expect(TextBlockContentV2.shouldRenderMarkdown(sample))
        }
    }

    @Test func storeReplaceAllAppliesSameIDUpdateAlongsideAppend() {
        let layout = MessageLayoutV2(itemSize: CGSize(width: 320, height: 44), blockLayouts: [])
        let original = RenderedMessageV2(
            id: "streaming",
            sequence: 1,
            text: "partial",
            isOutgoing: false,
            layout: layout
        )
        let updated = RenderedMessageV2(
            id: "streaming",
            sequence: 1,
            text: "complete",
            isOutgoing: false,
            layout: layout
        )
        let appended = RenderedMessageV2(
            id: "next",
            sequence: 2,
            text: "next message",
            isOutgoing: true,
            layout: layout
        )
        let store = ChatMessageStoreV2()

        store.initialLoad([original])
        store.replaceAll([updated, appended])

        #expect(store.messageIDs == ["streaming", "next"])
        #expect(store.messages.map(\.text) == ["complete", "next message"])
    }

    @Test func contiguousDiffTracksSameIDUpdateAlongsideAppend() throws {
        let layout = MessageLayoutV2(itemSize: CGSize(width: 320, height: 44), blockLayouts: [])
        let original = RenderedMessageV2(
            id: "streaming",
            sequence: 1,
            text: "partial",
            isOutgoing: false,
            layout: layout
        )
        let updated = RenderedMessageV2(
            id: "streaming",
            sequence: 1,
            text: "complete",
            isOutgoing: false,
            layout: layout
        )
        let appended = RenderedMessageV2(
            id: "next",
            sequence: 2,
            text: "next message",
            isOutgoing: true,
            layout: layout
        )

        let change = try #require(ChatContiguousChangeV2(
            previous: [original],
            next: [updated, appended]
        ))

        #expect(change.prependCount == 0)
        #expect(change.appendStart == 1)
        #expect(change.changedExistingIndices == [0])
    }

    @Test func contiguousDiffIgnoresSequenceShiftForUnchangedPrependedRows() throws {
        let layout = MessageLayoutV2(itemSize: CGSize(width: 320, height: 44), blockLayouts: [])
        let previous = [
            RenderedMessageV2(id: "existing-1", sequence: 0, text: "one", isOutgoing: false, layout: layout),
            RenderedMessageV2(id: "existing-2", sequence: 1, text: "two", isOutgoing: true, layout: layout)
        ]
        let next = [
            RenderedMessageV2(id: "older", sequence: 0, text: "older", isOutgoing: false, layout: layout),
            RenderedMessageV2(id: "existing-1", sequence: 1, text: "one", isOutgoing: false, layout: layout),
            RenderedMessageV2(id: "existing-2", sequence: 2, text: "two", isOutgoing: true, layout: layout)
        ]

        let change = try #require(ChatContiguousChangeV2(previous: previous, next: next))

        #expect(change.prependCount == 1)
        #expect(change.appendStart == 3)
        #expect(change.changedExistingIndices.isEmpty)
    }

    @Test func bridgeUpdateOrdersSnapshotBeforeHistoryStateAndScroll() {
        var events: [String] = []

        ChatRoomV2BridgeUpdateOrderingV2.apply(shouldApplyMessages: true) {
            events.append("snapshot")
        } applyHistoryState: {
            events.append("history")
        } applyScrollCommand: {
            events.append("scroll")
        }

        #expect(events == ["snapshot", "history", "scroll"])

        events.removeAll()
        ChatRoomV2BridgeUpdateOrderingV2.apply(shouldApplyMessages: false) {
            events.append("snapshot")
        } applyHistoryState: {
            events.append("history")
        } applyScrollCommand: {
            events.append("scroll")
        }

        #expect(events == ["history", "scroll"])
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

    @Test func rendererReusesPrecomputedTextCodeAndTableArtifactsForSameSnapshot() {
        let renderer = MessageRenderCoordinatorV2()
        let raw = ChatMessageV2(
            id: "artifact-message",
            sequence: 17,
            isOutgoing: false,
            blocks: [
                .text(TextBlockContentV2(
                    id: "artifact-text",
                    text: "**Cached Markdown** with https://example.test",
                    isMarkdown: true
                )),
                .code(CodeBlockContentV2(
                    id: "artifact-code",
                    code: "let cached = true",
                    language: "swift"
                )),
                .table(TableBlockContentV2(
                    id: "artifact-table",
                    rows: [["Artifact", "State"], ["Geometry", "Cached"]]
                ))
            ]
        )

        let traits = UITraitCollection { mutableTraits in
            mutableTraits.displayScale = 3
            mutableTraits.userInterfaceStyle = .light
        }
        let first = renderer.render(raw, containerWidth: 390, traitCollection: traits)
        let second = renderer.render(raw, containerWidth: 390, traitCollection: traits)

        guard let firstText = first.renderArtifacts.text(for: "artifact-text"),
              let secondText = second.renderArtifacts.text(for: "artifact-text"),
              let firstCode = first.renderArtifacts.code(for: "artifact-code"),
              let secondCode = second.renderArtifacts.code(for: "artifact-code"),
              let firstTable = first.renderArtifacts.table(for: "artifact-table"),
              let secondTable = second.renderArtifacts.table(for: "artifact-table")
        else {
            Issue.record("Expected renderer to precompute every reusable artifact")
            return
        }

        #expect(firstText.attributedText === secondText.attributedText)
        #expect(firstCode.plainAttributedText === secondCode.plainAttributedText)
        #expect(firstTable == secondTable)
        #expect(second.layout == first.layout)
    }

    @Test func rendererInvalidatesArtifactsWhenSameIDContentChanges() {
        let renderer = MessageRenderCoordinatorV2()
        let traits = UITraitCollection(displayScale: 3)
        let original = ChatMessageV2(
            id: "streaming-message",
            sequence: 18,
            text: "partial response",
            isOutgoing: false
        )
        let updated = ChatMessageV2(
            id: "streaming-message",
            sequence: 18,
            text: "complete response with an additional line",
            isOutgoing: false
        )

        let first = renderer.render(original, containerWidth: 390, traitCollection: traits)
        let second = renderer.render(updated, containerWidth: 390, traitCollection: traits)

        guard let firstArtifact = first.renderArtifacts.text(for: "streaming-message-text-0"),
              let secondArtifact = second.renderArtifacts.text(for: "streaming-message-text-0")
        else {
            Issue.record("Expected text artifacts for both streaming snapshots")
            return
        }

        #expect(firstArtifact.attributedText !== secondArtifact.attributedText)
        #expect(secondArtifact.attributedText.string.contains("complete response"))
        #expect(second.layout.itemSize.height >= first.layout.itemSize.height)
    }

    @Test func rendererSeparatesPointWidthFromDisplayScaleAndReusesArtifacts() throws {
        let renderer = MessageRenderCoordinatorV2()
        let raw = ChatMessageV2(
            id: "external-display-message",
            sequence: 19,
            text: "**Reusable Markdown** across displays",
            isOutgoing: false
        )
        let threeX = UITraitCollection { mutableTraits in
            mutableTraits.displayScale = 3
            mutableTraits.userInterfaceStyle = .light
        }
        let twoX = UITraitCollection { mutableTraits in
            mutableTraits.displayScale = 2
            mutableTraits.userInterfaceStyle = .light
        }

        let compact = renderer.render(raw, containerWidth: 390, traitCollection: threeX)
        let wide = renderer.render(raw, containerWidth: 585, traitCollection: twoX)
        let compactText = try #require(compact.renderArtifacts.text(for: "external-display-message-text-0"))
        let wideText = try #require(wide.renderArtifacts.text(for: "external-display-message-text-0"))

        #expect(compact.layout.itemSize.width == 390)
        #expect(wide.layout.itemSize.width == 585)
        #expect(compactText.attributedText === wideText.attributedText)
        #expect(compact.renderScale == 3)
        #expect(wide.renderScale == 2)
    }

    @Test func rendererInvalidatesAppearanceDependentArtifactsWhenStyleChanges() {
        let renderer = MessageRenderCoordinatorV2()
        let raw = ChatMessageV2(
            id: "appearance-message",
            sequence: 19,
            isOutgoing: false,
            blocks: [
                .code(CodeBlockContentV2(
                    id: "appearance-code",
                    code: "let appearance = traitCollection.userInterfaceStyle",
                    language: "swift"
                ))
            ]
        )
        let lightTraits = UITraitCollection { mutableTraits in
            mutableTraits.displayScale = 3
            mutableTraits.userInterfaceStyle = .light
        }
        let darkTraits = UITraitCollection { mutableTraits in
            mutableTraits.displayScale = 3
            mutableTraits.userInterfaceStyle = .dark
        }

        let light = renderer.render(raw, containerWidth: 390, traitCollection: lightTraits)
        let dark = renderer.render(raw, containerWidth: 390, traitCollection: darkTraits)
        guard let lightArtifact = light.renderArtifacts.code(for: "appearance-code"),
              let darkArtifact = dark.renderArtifacts.code(for: "appearance-code")
        else {
            Issue.record("Expected appearance-dependent code artifacts")
            return
        }
        let lightColor = lightArtifact.plainAttributedText.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? UIColor
        let darkColor = darkArtifact.plainAttributedText.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? UIColor

        #expect(lightArtifact.plainAttributedText !== darkArtifact.plainAttributedText)
        #expect(lightColor != darkColor)
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

    @Test func bridgeSnapshotSignatureDetectsSameIDContentChangesAndNormalizesUserID() {
        let original = message(id: "message-1", sequence: 1, body: "partial")
        let updated = message(id: "message-1", sequence: 1, body: "complete")
        let originalSignature = ChatRoomV2BridgeSnapshotSignature(
            messages: [original],
            currentUserID: " User ",
            revision: nil
        )
        let sameSignature = ChatRoomV2BridgeSnapshotSignature(
            messages: [original],
            currentUserID: "user",
            revision: nil
        )
        let updatedSignature = ChatRoomV2BridgeSnapshotSignature(
            messages: [updated],
            currentUserID: "user",
            revision: nil
        )
        let coordinator = ChatRoomUIKitV2MessageListView.Coordinator()

        #expect(originalSignature == sameSignature)
        #expect(originalSignature != updatedSignature)
        #expect(coordinator.shouldApplyMessages(originalSignature))
        #expect(!coordinator.shouldApplyMessages(sameSignature))
        #expect(coordinator.shouldApplyMessages(updatedSignature))
    }

    @Test func bridgeSnapshotSignatureCanonicalizesMetadataDictionaryOrder() {
        let firstMetadata: [String: AnyCodable] = [
            "beta": AnyCodable(2),
            "alpha": AnyCodable(["nested": AnyCodable("value")])
        ]
        let secondMetadata: [String: AnyCodable] = [
            "alpha": AnyCodable(["nested": AnyCodable("value")]),
            "beta": AnyCodable(2)
        ]
        let first = message(id: "metadata-message", sequence: 2, body: "image", metadata: firstMetadata)
        let second = message(id: "metadata-message", sequence: 2, body: "image", metadata: secondMetadata)

        #expect(ChatRoomV2MessageContentSignature(first) == ChatRoomV2MessageContentSignature(second))
    }

    @Test func bridgeSnapshotRevisionProvidesConstantSizeFastPath() {
        let original = message(id: "message-1", sequence: 1, body: "partial")
        let updated = message(id: "message-1", sequence: 1, body: "complete")
        let revision42 = ChatRoomV2BridgeSnapshotSignature(
            messages: [original],
            currentUserID: "user",
            revision: 42
        )
        let sameRevision = ChatRoomV2BridgeSnapshotSignature(
            messages: [updated],
            currentUserID: "user",
            revision: 42
        )
        let nextRevision = ChatRoomV2BridgeSnapshotSignature(
            messages: [updated],
            currentUserID: "user",
            revision: 43
        )

        #expect(revision42.contentSignatures == nil)
        #expect(revision42 == sameRevision)
        #expect(revision42 != nextRevision)
    }

    @Test func skippedLiveSnapshotRevisionFallsBackToFullSignatureValidation() {
        let changedOnlyInNewestSnapshot: Set<String> = ["message-b"]

        let consecutive = ChatLiveSnapshotRevisionPolicyV2.trustedChangedMessageIDs(
            snapshotRevision: 2,
            lastAppliedRevision: 1,
            candidateIDs: changedOnlyInNewestSnapshot
        )
        let skippedIntermediateSnapshot = ChatLiveSnapshotRevisionPolicyV2.trustedChangedMessageIDs(
            snapshotRevision: 3,
            lastAppliedRevision: 1,
            candidateIDs: changedOnlyInNewestSnapshot
        )
        let firstSnapshot = ChatLiveSnapshotRevisionPolicyV2.trustedChangedMessageIDs(
            snapshotRevision: 1,
            lastAppliedRevision: nil,
            candidateIDs: changedOnlyInNewestSnapshot
        )

        #expect(consecutive == changedOnlyInNewestSnapshot)
        #expect(skippedIntermediateSnapshot == nil)
        #expect(firstSnapshot == nil)
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

    @Test func localImageStoreReadsAndReplacesCachedDataOffMainPath() async throws {
        let store = LocalImageStore()
        let block = ImageBlockContentV2(
            id: "async-image-cache-test",
            urlString: "https://example.test/media/async-image-cache-test.png",
            name: "async-image-cache-test.png",
            aspectRatio: 1,
            isSticker: false
        )
        let expected = Data([0x01, 0x02, 0x03, 0x04, 0x05])

        let cachedURL = await store.cacheImageDataAsync(
            expected,
            for: block.cacheContent,
            fallbackIdentifier: block.id,
            replacingExisting: true
        )
        let loaded = await store.cachedImageData(
            for: block.cacheContent,
            fallbackIdentifier: block.id
        )

        #expect(cachedURL != nil)
        #expect(loaded == expected)
    }

    @Test func imageDownsamplerBoundsDecodedPixelDimensions() throws {
        let sourceData = try #require(makeImageData(size: CGSize(width: 1_200, height: 800)))

        let image = try #require(ChatImageDownsamplerV2.downsampledImageSynchronously(
            from: sourceData,
            targetPointSize: CGSize(width: 120, height: 80),
            scale: 2
        ))
        let cgImage = try #require(image.cgImage)

        #expect(cgImage.width <= 240)
        #expect(cgImage.height <= 160)
        #expect(cgImage.width < 1_200)
        #expect(cgImage.height < 800)
        #expect(abs(CGFloat(cgImage.width) / CGFloat(cgImage.height) - 1.5) < 0.02)
        #expect(ChatImageDownsamplerV2.memoryCost(of: image) == cgImage.bytesPerRow * cgImage.height)
    }

    @Test func imagePipelineCoalescesIdenticalRequestsAndCachesResult() async throws {
        let sourceData = try #require(makeImageData(size: CGSize(width: 900, height: 600)))
        let pipeline = ChatImagePipelineV2(countLimit: 4, totalCostLimit: 4 * 1024 * 1024)
        let gate = ChatImagePipelineTestGate()
        let sourceIdentifier = "fixture://coalesced-image"
        let targetSize = CGSize(width: 150, height: 100)
        var loaderCalls = 0

        let firstRequest = Task { @MainActor in
            await pipeline.image(
                sourceIdentifier: sourceIdentifier,
                targetPointSize: targetSize,
                scale: 2
            ) {
                loaderCalls += 1
                await gate.markLoaderStartedAndWait()
                return sourceData
            }
        }
        await gate.waitUntilLoaderStarted()

        let secondRequest = Task { @MainActor in
            await pipeline.image(
                sourceIdentifier: sourceIdentifier,
                targetPointSize: targetSize,
                scale: 2
            ) {
                loaderCalls += 1
                return sourceData
            }
        }
        for _ in 0..<3 { await Task.yield() }
        await gate.open()

        let (firstImage, secondImage) = await (firstRequest.value, secondRequest.value)
        let cached = pipeline.cachedImage(
            sourceIdentifier: sourceIdentifier,
            targetPointSize: targetSize,
            scale: 2
        )

        #expect(loaderCalls == 1)
        #expect(firstImage != nil)
        #expect(firstImage === secondImage)
        #expect(cached === firstImage)
    }

    @Test func imagePipelineCancelsLastWaiterWithoutCachingOffscreenWork() async throws {
        let sourceData = try #require(makeImageData(size: CGSize(width: 900, height: 600)))
        let pipeline = ChatImagePipelineV2(countLimit: 4, totalCostLimit: 4 * 1024 * 1024)
        let gate = ChatImagePipelineTestGate()
        let sourceIdentifier = "fixture://cancelled-image"
        let targetSize = CGSize(width: 150, height: 100)

        let request = Task { @MainActor in
            await pipeline.image(
                sourceIdentifier: sourceIdentifier,
                targetPointSize: targetSize,
                scale: 2
            ) {
                await gate.markLoaderStartedAndWait()
                return sourceData
            }
        }
        await gate.waitUntilLoaderStarted()
        request.cancel()

        let cancelledImage = await request.value
        #expect(cancelledImage == nil)
        #expect(pipeline.cachedImage(
            sourceIdentifier: sourceIdentifier,
            targetPointSize: targetSize,
            scale: 2
        ) == nil)
        await gate.open()
    }

    @Test func imagePipelineFallsBackWhenPrimaryCacheDataIsCorrupt() async throws {
        let validData = try #require(makeImageData(size: CGSize(width: 900, height: 600)))
        let pipeline = ChatImagePipelineV2(countLimit: 4, totalCostLimit: 4 * 1024 * 1024)
        var fallbackCalls = 0

        let image = await pipeline.image(
            sourceIdentifier: "fixture://corrupt-primary",
            targetPointSize: CGSize(width: 150, height: 100),
            scale: 2,
            fallbackDataLoader: {
                fallbackCalls += 1
                return validData
            }
        ) {
            Data([0x00, 0x01, 0x02])
        }

        #expect(image != nil)
        #expect(fallbackCalls == 1)
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

    @Test func mutationCoordinatorCoalescesPendingLiveSnapshotsToLatest() {
        let coordinator = ChatMutationCoordinatorV2()
        var events: [String] = []
        var finishInFlight: (() -> Void)?

        coordinator.enqueue { finish in
            events.append("in-flight")
            finishInFlight = finish
        }
        coordinator.enqueueLatest(for: .liveSnapshot) { finish in
            events.append("stale-snapshot")
            finish()
        }
        coordinator.enqueueLatest(for: .liveSnapshot) { finish in
            events.append("latest-snapshot")
            finish()
        }

        #expect(events == ["in-flight"])
        #expect(coordinator.pendingCount == 1)

        finishInFlight?()

        #expect(events == ["in-flight", "latest-snapshot"])
        #expect(!coordinator.isBusy)
        #expect(coordinator.pendingCount == 0)
    }

    @Test func mutationCoordinatorKeepsLatestScrollBehindLatestSnapshot() {
        let coordinator = ChatMutationCoordinatorV2()
        var events: [String] = []
        var finishInFlight: (() -> Void)?

        coordinator.enqueue { finish in
            events.append("in-flight")
            finishInFlight = finish
        }
        coordinator.enqueueLatest(for: .scrollCommand) { finish in
            events.append("stale-scroll")
            finish()
        }
        coordinator.enqueueLatest(for: .liveSnapshot) { finish in
            events.append("latest-snapshot")
            finish()
        }
        coordinator.enqueueLatest(for: .scrollCommand) { finish in
            events.append("latest-scroll")
            finish()
        }

        #expect(coordinator.pendingCount == 2)
        finishInFlight?()

        #expect(events == ["in-flight", "latest-snapshot", "latest-scroll"])
        #expect(!coordinator.isBusy)
    }

    @Test func mutationCoordinatorAppliesLatestHistoryStateAfterLatestSnapshot() {
        let coordinator = ChatMutationCoordinatorV2()
        var events: [String] = []
        var finishInFlight: (() -> Void)?

        coordinator.enqueue { finish in
            events.append("in-flight")
            finishInFlight = finish
        }
        coordinator.enqueueLatest(for: .liveSnapshot) { finish in
            events.append("stale-snapshot")
            finish()
        }
        coordinator.enqueueLatest(for: .liveHistoryState) { finish in
            events.append("loading")
            finish()
        }
        coordinator.enqueueLatest(for: .liveSnapshot) { finish in
            events.append("latest-snapshot")
            finish()
        }
        coordinator.enqueueLatest(for: .liveHistoryState) { finish in
            events.append("idle")
            finish()
        }

        #expect(coordinator.pendingCount == 2)
        finishInFlight?()

        #expect(events == ["in-flight", "latest-snapshot", "idle"])
        #expect(!coordinator.isBusy)
    }

    @Test func controllerCoalescesLiveHistoryStateBehindSnapshotMutation() {
        let coordinator = ChatMutationCoordinatorV2()
        let controller = ChatRoomUIKitV2ViewController(
            context: ChatContext(id: "test", title: "Test", subtitle: "", isGroup: false),
            mutationCoordinator: coordinator
        )
        var events: [String] = []
        var finishInFlight: (() -> Void)?

        coordinator.enqueue { finish in
            events.append("in-flight")
            finishInFlight = finish
        }
        coordinator.enqueueLatest(for: .liveSnapshot) { finish in
            events.append("snapshot")
            finish()
        }
        controller.applyLiveHistoryState(isLoadingOlder: true, hasMoreHistory: true)

        #expect(controller.liveHistoryStateSnapshot == ChatLiveHistoryStateSnapshotV2(
            isLoadingOlder: false,
            hasMoreHistory: true,
            hasPendingRequest: false
        ))
        #expect(coordinator.pendingCount == 2)

        controller.applyLiveHistoryState(isLoadingOlder: false, hasMoreHistory: true)
        #expect(coordinator.pendingCount == 2)
        finishInFlight?()

        #expect(events == ["in-flight", "snapshot"])
        #expect(controller.liveHistoryStateSnapshot == ChatLiveHistoryStateSnapshotV2(
            isLoadingOlder: false,
            hasMoreHistory: true,
            hasPendingRequest: false
        ))
        #expect(!coordinator.isBusy)
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

    @Test func liveMessagesUseSourceOrderForPendingAndFailedRows() {
        let remote = message(id: "remote-100", sequence: 100, body: "remote")
        let failed = message(id: "failed", sequence: nil, body: "failed", failed: true)
        let optimistic = message(id: "pending", sequence: nil, body: "pending", pending: true)

        let rendered = [remote, failed, optimistic].enumerated().map { index, message in
            ChatMessageV2(
                message: message,
                currentUserID: "user",
                fallbackSequence: index,
                preservesSourceOrder: true
            )
        }

        #expect(rendered.map(\.sequence) == [0, 1, 2])
        #expect(rendered.map(\.id) == ["remote-100", "failed", "pending"])
        #expect(rendered[1].status?.displayText.contains(L10n.t("发送失败", "Failed")) == true)
        #expect(rendered.last?.id == "pending")
    }

    @Test func optimisticMessagesUseSequenceAfterRemoteHistoryWhenSourceOrderIsNotForced() {
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
            return ChatMessageV2(
                message: message,
                currentUserID: "user",
                fallbackSequence: fallbackSequence
            )
        }

        #expect(rendered.map(\.sequence) == [100, 101])
        #expect(rendered.last?.id == "pending")
    }

    private func message(
        id: String,
        sequence: Int?,
        body: String,
        pending: Bool = false,
        failed: Bool = false,
        metadata: [String: AnyCodable]? = nil
    ) -> Message {
        var message = Message(
            from: RealtimeMessagePayload(
                id: id,
                topic: "chat/dm/user/user/bot/bot",
                conversationId: "chat/dm/user/user/bot/bot",
                timestamp: Int64(1_800_000_000 + (sequence ?? 101)),
                from: MessagePeerPayload(type: "user", id: "user", name: "User", avatar: nil),
                to: MessagePeerPayload(type: "bot", id: "bot", name: "Bot", avatar: nil),
                content: RealtimeContentPayload(type: "text", body: body, url: nil, name: nil, size: nil, meta: metadata),
                seq: sequence.map(Int64.init)
            ),
            pending: pending
        )
        message.failed = failed
        return message
    }

    private func makeImageData(size: CGSize) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.85)
    }
}

private actor ChatImagePipelineTestGate {
    private var isOpen = false
    private var loaderStarted = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func markLoaderStartedAndWait() async {
        loaderStarted = true
        let startWaiters = self.startWaiters
        self.startWaiters.removeAll()
        startWaiters.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilLoaderStarted() async {
        guard !loaderStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let openWaiters = self.openWaiters
        self.openWaiters.removeAll()
        openWaiters.forEach { $0.resume() }
    }
}

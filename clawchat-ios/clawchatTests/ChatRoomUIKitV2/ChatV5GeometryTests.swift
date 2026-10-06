import Testing
import UIKit
@testable import clawchat

@MainActor
struct ChatV5GeometryTests {
    @Test func attachmentCompletionPreservesEditsMadeWhileUploading() {
        let model = ChatRoomViewModel(conversationId: "fixture", observesRealtime: false)
        let document = DocumentLinkPreview(id: UUID(), path: "/documents/original", title: "Original", summary: "", documentType: "MARKDOWN", updatedLabel: "")
        let nextDocument = DocumentLinkPreview(id: UUID(), path: "/documents/next", title: "Next", summary: "", documentType: "MARKDOWN", updatedLabel: "")
        for (text, reference) in [
            ("Next message typed during upload", document),
            ("Uploaded caption", nextDocument),
            ("Next message typed during upload", nextDocument)
        ] {
            model.inputText = text
            model.editingDocument = reference
            model.finishPublishedAttachmentDraft(text: "Uploaded caption", document: document)
            #expect(model.inputText == text)
            #expect(model.editingDocument == reference)
        }

        model.inputText = "Uploaded caption"
        model.editingDocument = document
        model.finishPublishedAttachmentDraft(text: "Uploaded caption", document: document)
        #expect(model.inputText.isEmpty)
        #expect(model.editingDocument == nil)
    }

    @Test(arguments: ["text", "image", "file"])
    func documentEditsKeepUserInstructionsAndReferenceWithoutRawPathsInBubbles(kind: String) {
        let id = UUID()
        let request = "Shorten the introduction.\nKeep the original sources."
        let document = DocumentLinkPreview(id: id, path: "/documents/\(id.uuidString.lowercased())", title: "Research notes", summary: "A saved document", documentType: "MARKDOWN", updatedLabel: "Updated just now")
        let draft = ChatRoomViewModel.documentEditContent(request: request, document: document)
        #expect(draft.body?.contains(document.path) == true)
        #expect(draft.body?.contains(request) == true)
        let source = Message(from: RealtimeMessagePayload(
            id: "document-edit", topic: "fixture", conversationId: "fixture", timestamp: 1,
            from: .init(type: "user", id: "me", name: nil, avatar: nil),
            to: .init(type: "bot", id: "bot", name: nil, avatar: nil),
            content: .init(type: kind, body: draft.body, url: "https://example.test/reference.png", name: "reference.png", size: 1024, meta: draft.meta), seq: 1
        ))
        let rendered = ChatMessageV2(message: source, currentUserID: "me", fallbackSequence: 1)
        #expect(rendered.text == request)
        #expect(!rendered.text.contains(document.path))
        #expect(rendered.blocks.contains { block in
            if case .document(let value) = block { return value.preview.id == id && value.preview.title == document.title }
            return false
        })
        for width in [CGFloat(320), 393, 768] {
            let layout = MessageRenderCoordinatorV2().render(rendered, containerWidth: width, traitCollection: .init()).layout
            for (previous, next) in zip(layout.blockLayouts, layout.blockLayouts.dropFirst()) {
                #expect(next.frame.minY - previous.frame.maxY == 8)
            }
        }
    }

    @Test(arguments: [CGFloat(320), 393, 430, 768])
    func contentUsesConsistentEdgesAndSpacing(width: CGFloat) {
        let renderer = MessageRenderCoordinatorV2()
        let blocks: [MessageBlockContentV2] = [
            .text(.init(id: "text", text: "一条短消息", isMarkdown: false)),
            .image(.init(id: "image", urlString: "https://example.test/image.jpg", name: "image", aspectRatio: 1.5, isSticker: false)),
            .audio(.init(id: "audio", urlString: "https://example.test/audio.m4a", durationSeconds: 8, durationLabel: "8s"))
        ]
        for outgoing in [false, true] {
            let raw = ChatMessageV2(id: "mixed", sequence: 1, isOutgoing: outgoing, blocks: blocks,
                                   sender: .init(displayName: "Bot", avatarURLString: "https://example.test/avatar.png", isBot: true, showsName: false))
            let layout = renderer.render(raw, containerWidth: width, traitCollection: .init(displayScale: 3)).layout
            #expect(layout.blockLayouts.count == blocks.count)
            #expect(layout.blockLayouts.first?.frame.minY == 5)
            #expect(layout.itemSize.height - layout.blockLayouts.last!.frame.maxY == 5)
            for frame in layout.blockLayouts.map(\.frame) {
                #expect(outgoing ? abs(frame.maxX - (width - 16)) < 0.01 : frame.minX == 16)
                #expect(frame.width <= ChatLayoutMetrics.bubbleWidth(in: width))
            }
            for pair in zip(layout.blockLayouts, layout.blockLayouts.dropFirst()) {
                #expect(pair.1.frame.minY - pair.0.frame.maxY == 8)
            }
        }
    }

    @Test func uploadedFileKeepsAssetIdentityAndCompactGeometry() {
        let source = HomeV5Preview.files[0]
        let message = ChatMessageV2(message: source, currentUserID: "preview-user", fallbackSequence: 1)
        #expect(message.blocks.count == 1)
        guard case .file(let file) = message.blocks[0] else {
            Issue.record("Uploaded files must render as a tappable file block")
            return
        }
        #expect(file.assetID == "00000000-0000-4000-8000-000000000005")
        #expect(file.name == "AI应用简报.md")
        let rendered = MessageRenderCoordinatorV2().render(message, containerWidth: 393, traitCollection: .init())
        #expect(rendered.layout.itemSize.height == 86)
    }

    @Test func shortMessageDoesNotReserveAvatarHeight() {
        let renderer = MessageRenderCoordinatorV2()
        let raw = ChatMessageV2(id: "short", sequence: 1, text: "OK", isOutgoing: false)
        let layout = renderer.render(raw, containerWidth: 393, traitCollection: .init(displayScale: 3)).layout
        #expect(layout.itemSize.height == layout.blockLayouts[0].frame.height + 10)
        #expect(layout.blockLayouts[0].frame.minX == 16)
    }

    @Test func ordinaryMessageHasNoMetadataRowWhileDeliveryFailuresRemainVisible() {
        var source = HomeV5Preview.messages[0]
        let sent = ChatMessageV2(message: source, currentUserID: "preview-user", fallbackSequence: 1)
        #expect(sent.status == nil)
        source.failed = true
        let failed = ChatMessageV2(message: source, currentUserID: "preview-user", fallbackSequence: 1)
        #expect(failed.status?.isFailed == true)
        #expect(failed.status?.timestampText == nil)
    }

    @Test func groupNameAddsOnlyOneSmallLabelAndNoAvatar() {
        let source = HomeV5Preview.messages[1]
        let renderer = MessageRenderCoordinatorV2()
        let direct = renderer.render(ChatMessageV2(message: source, currentUserID: "preview-user", fallbackSequence: 1), containerWidth: 393, traitCollection: .init())
        let group = renderer.render(ChatMessageV2(message: source, currentUserID: "preview-user", fallbackSequence: 1, showsSenderInfo: true), containerWidth: 393, traitCollection: .init())
        #expect(group.layout.itemSize.height - direct.layout.itemSize.height == 20)
        #expect(group.layout.blockLayouts.count == direct.layout.blockLayouts.count + 1)
        #expect(!group.layout.blockLayouts.contains { $0.id.hasSuffix("-avatar") })
    }

    @Test(arguments: [CGFloat(320), 393, 768])
    func measuredMultilineTextFitsNativeTextView(width: CGFloat) {
        let renderer = MessageRenderCoordinatorV2()
        for text in ["你好 👋🏻\n这是带有中英文的消息。Hello world!", String(repeating: "Long messages should wrap without clipping. 长消息需要完整展示。\n", count: 8), "**重点**\n\n- 第一项内容\n- 第二项内容"] {
            let raw = ChatMessageV2(id: "text", sequence: 1, text: text, isOutgoing: false)
            let rendered = renderer.render(raw, containerWidth: width, traitCollection: .init(displayScale: 3))
            for block in rendered.blocks {
                guard case .text(let content) = block, let frame = rendered.layout.blockLayouts.first(where: { $0.id == block.id })?.frame else { continue }
                let view = UITextView()
                view.textContainerInset = .zero
                view.textContainer.lineFragmentPadding = 0
                view.isScrollEnabled = false
                view.attributedText = MessageTextFormatterV2.attributedString(for: content.text, isOutgoing: false, rendersMarkdown: content.isMarkdown)
                let fitted = view.sizeThatFits(CGSize(width: frame.width - 24, height: .greatestFiniteMagnitude))
                #expect(fitted.height <= frame.height - 20 + 1, "Text is clipped at width \(width): \(fitted.height) vs \(frame.height)")
            }
        }
    }
}

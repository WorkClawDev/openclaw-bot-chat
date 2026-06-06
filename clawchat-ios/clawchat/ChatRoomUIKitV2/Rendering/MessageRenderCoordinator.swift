import Foundation
import UIKit

actor MessageRenderCoordinator {
    private let currentUserID: String
    private let themeVersion: String
    private let layoutEngine: RichTextLayoutEngine

    init(
        currentUserID: String,
        themeVersion: String = "default",
        layoutEngine: RichTextLayoutEngine = RichTextLayoutEngine()
    ) {
        self.currentUserID = currentUserID
        self.themeVersion = themeVersion
        self.layoutEngine = layoutEngine
    }

    func render(_ message: RawMessage, width: CGFloat) async -> RenderedMessage {
        let maxBubbleWidth = Self.maxBubbleWidth(for: width)
        let textWidth = max(1, maxBubbleWidth - Self.bubbleHorizontalPadding * 2)
        let text: String

        switch message.content {
        case .text(let value):
            text = value
        }

        let richText = layoutEngine.layout(text: text, maxWidth: textWidth)
        let blockID = Self.stableBlockID(
            messageID: message.id,
            blockType: "richText",
            blockOrdinal: 0,
            content: text
        )
        let block = RichTextBlock(
            id: blockID,
            attributedText: richText.attributedText,
            measuredHeight: richText.measuredHeight
        )
        let rowHeight = Self.rowHeight(textHeight: richText.measuredHeight)
        let layout = MessageLayout(
            rowHeight: rowHeight,
            bubbleMaxWidth: maxBubbleWidth,
            textWidth: textWidth,
            textHeight: richText.measuredHeight
        )

        return RenderedMessage(
            id: message.id,
            senderID: message.senderID,
            isMe: message.senderID == currentUserID,
            blocks: [.richText(block)],
            layout: layout,
            contentVersion: message.contentVersion,
            status: message.status
        )
    }

    func renderPage(_ messages: [RawMessage], width: CGFloat) async -> [RenderedMessage] {
        var rendered: [RenderedMessage] = []
        rendered.reserveCapacity(messages.count)

        for message in messages {
            rendered.append(await render(message, width: width))
        }

        return rendered
    }

    static func maxBubbleWidth(for containerWidth: CGFloat) -> CGFloat {
        min(320, max(180, floor(containerWidth * 0.74)))
    }

    static func rowHeight(textHeight: CGFloat) -> CGFloat {
        let bubbleHeight = textHeight + bubbleVerticalPadding * 2
        return ceil(max(avatarSize, bubbleHeight) + cellVerticalPadding * 2)
    }

    static func stableBlockID(
        messageID: String,
        blockType: String,
        blockOrdinal: Int,
        content: String
    ) -> String {
        "\(messageID):\(blockType):\(blockOrdinal):\(ChatRoomV2ContentHasher.hash(content))"
    }

    static let avatarSize: CGFloat = 36
    static let cellVerticalPadding: CGFloat = 6
    static let bubbleHorizontalPadding: CGFloat = 12
    static let bubbleVerticalPadding: CGFloat = 8
}

enum ChatRoomV2ContentHasher {
    static func hash(_ string: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

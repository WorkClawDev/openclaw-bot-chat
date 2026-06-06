import Foundation

struct RenderedMessage: Identifiable, Equatable {
    let id: String
    let senderID: String
    let isMe: Bool
    let blocks: [RenderedBlock]
    let layout: MessageLayout
    let contentVersion: String
    let status: MessageStatus

    var firstRichTextBlock: RichTextBlock? {
        for block in blocks {
            if case .richText(let richTextBlock) = block {
                return richTextBlock
            }
        }
        return nil
    }
}

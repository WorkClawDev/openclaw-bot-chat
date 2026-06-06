import Foundation
import UIKit

protocol IdentifiedBlock {
    var id: String { get }
}

struct RichTextBlock: IdentifiedBlock, Equatable {
    let id: String
    let attributedText: NSAttributedString
    let measuredHeight: CGFloat

    static func == (lhs: RichTextBlock, rhs: RichTextBlock) -> Bool {
        lhs.id == rhs.id &&
        lhs.attributedText.string == rhs.attributedText.string &&
        lhs.measuredHeight == rhs.measuredHeight
    }
}

enum RenderedBlock: Equatable {
    case richText(RichTextBlock)

    var id: String {
        switch self {
        case .richText(let block):
            return block.id
        }
    }
}

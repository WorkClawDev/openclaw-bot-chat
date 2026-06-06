import Foundation
import UIKit

struct MessageLayoutCacheKey: Hashable {
    let messageID: String
    let contentVersion: String
    let containerWidth: Int
    let themeVersion: String
    let contentSizeCategory: UIContentSizeCategory
}

struct MessageLayout: Equatable {
    let rowHeight: CGFloat
    let bubbleMaxWidth: CGFloat
    let textWidth: CGFloat
    let textHeight: CGFloat
}

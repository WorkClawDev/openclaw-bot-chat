import Foundation
import UIKit

struct RichTextLayoutResult {
    let attributedText: NSAttributedString
    let measuredHeight: CGFloat
}

struct RichTextLayoutEngine {
    let font: UIFont
    let textColor: UIColor

    init(
        font: UIFont = .preferredFont(forTextStyle: .body),
        textColor: UIColor = .label
    ) {
        self.font = font
        self.textColor = textColor
    }

    func layout(text: String, maxWidth: CGFloat) -> RichTextLayoutResult {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = 2

        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle
            ]
        )
        let constrainedSize = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
        let rect = attributedText.boundingRect(
            with: constrainedSize,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )

        return RichTextLayoutResult(
            attributedText: attributedText,
            measuredHeight: ceil(rect.height)
        )
    }
}

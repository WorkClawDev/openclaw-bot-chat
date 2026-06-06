import Foundation
import UIKit

protocol MessageBlockView: AnyObject {
    func configure(with block: RenderedBlock)
    func prepareForReuse()
}

final class ChatMessageCell: UITableViewCell {
    static let reuseIdentifier = "ChatRoomUIKitV2.ChatMessageCell"

    private let avatarImageView = UIImageView()
    private let bubbleContainerView = UIView()
    private let textView = UITextView()
    private var textHeightConstraint: NSLayoutConstraint?
    private var bubbleWidthConstraint: NSLayoutConstraint?
    private var leadingBubbleConstraint: NSLayoutConstraint?
    private var trailingBubbleConstraint: NSLayoutConstraint?
    private var representedMessageID: String?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedMessageID = nil
        avatarImageView.image = nil
        textView.attributedText = nil
        textHeightConstraint?.constant = 0
    }

    func configure(with message: RenderedMessage) {
        representedMessageID = message.id
        selectionStyle = .none

        let richTextBlock = message.firstRichTextBlock
        if let attributedText = richTextBlock?.attributedText {
            let mutableText = NSMutableAttributedString(attributedString: attributedText)
            mutableText.addAttribute(
                .foregroundColor,
                value: message.isMe ? UIColor.white : UIColor.label,
                range: NSRange(location: 0, length: mutableText.length)
            )
            textView.attributedText = mutableText
        } else {
            textView.attributedText = nil
        }
        textHeightConstraint?.constant = message.layout.textHeight
        bubbleWidthConstraint?.constant = message.layout.bubbleMaxWidth

        let bubbleColor: UIColor = message.isMe ? .systemBlue : .secondarySystemBackground
        let textColor: UIColor = message.isMe ? .white : .label
        bubbleContainerView.backgroundColor = bubbleColor
        textView.textColor = textColor
        avatarImageView.backgroundColor = message.isMe ? .systemBlue.withAlphaComponent(0.18) : .tertiarySystemFill
        avatarImageView.tintColor = message.isMe ? .systemBlue : .secondaryLabel
        avatarImageView.image = UIImage(systemName: message.isMe ? "person.fill" : "bubble.left.fill")

        leadingBubbleConstraint?.isActive = !message.isMe
        trailingBubbleConstraint?.isActive = message.isMe
        setNeedsLayout()
    }

    private func setup() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.contentMode = .center
        avatarImageView.layer.cornerRadius = MessageRenderCoordinator.avatarSize / 2
        avatarImageView.clipsToBounds = true

        bubbleContainerView.translatesAutoresizingMaskIntoConstraints = false
        bubbleContainerView.layer.cornerRadius = 16
        bubbleContainerView.layer.cornerCurve = .continuous
        bubbleContainerView.clipsToBounds = true

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isScrollEnabled = false
        textView.isEditable = false
        textView.isSelectable = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true

        contentView.addSubview(avatarImageView)
        contentView.addSubview(bubbleContainerView)
        bubbleContainerView.addSubview(textView)

        textHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 0)
        bubbleWidthConstraint = bubbleContainerView.widthAnchor.constraint(equalToConstant: 220)
        leadingBubbleConstraint = bubbleContainerView.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 8)
        trailingBubbleConstraint = bubbleContainerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12)

        NSLayoutConstraint.activate([
            avatarImageView.widthAnchor.constraint(equalToConstant: MessageRenderCoordinator.avatarSize),
            avatarImageView.heightAnchor.constraint(equalToConstant: MessageRenderCoordinator.avatarSize),
            avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            avatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: MessageRenderCoordinator.cellVerticalPadding),

            bubbleContainerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: MessageRenderCoordinator.cellVerticalPadding),
            bubbleWidthConstraint!,

            textView.leadingAnchor.constraint(equalTo: bubbleContainerView.leadingAnchor, constant: MessageRenderCoordinator.bubbleHorizontalPadding),
            textView.trailingAnchor.constraint(equalTo: bubbleContainerView.trailingAnchor, constant: -MessageRenderCoordinator.bubbleHorizontalPadding),
            textView.topAnchor.constraint(equalTo: bubbleContainerView.topAnchor, constant: MessageRenderCoordinator.bubbleVerticalPadding),
            textView.bottomAnchor.constraint(equalTo: bubbleContainerView.bottomAnchor, constant: -MessageRenderCoordinator.bubbleVerticalPadding),
            textHeightConstraint!
        ])
    }
}

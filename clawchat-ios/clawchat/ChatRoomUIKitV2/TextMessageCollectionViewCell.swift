import HighlightSwift
import UIKit

final class TextMessageCollectionViewCell: UICollectionViewCell {
    static let reuseIdentifier = "TextMessageCollectionViewCell"

    private var renderedMessage: RenderedMessageV2?
    private var blockViews: [String: UIView] = [:]
    private var imageTasks: [String: Task<Void, Never>] = [:]
    private var imageRequestIDs: [String: UUID] = [:]
    private var codeTasks: [String: Task<Void, Never>] = [:]
    private var avatarTask: Task<Void, Never>?
    private var avatarRequestID: UUID?
    private var audioObservationIDs: [String: UUID] = [:]
    private var audioLoadingViews: [String: UIActivityIndicatorView] = [:]
    private var textBlockViewPool: [ReusableTextMessageBlockViewV2] = []

    var onImageTap: ((String) -> Void)?
    var onDocumentTap: ((UUID) -> Void)?
    var onDocumentContinueTap: ((DocumentLinkPreview) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureViews()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        resetRenderedContent()
        renderedMessage = nil
        onImageTap = nil
        onDocumentTap = nil
        onDocumentContinueTap = nil
    }

    func configure(with message: RenderedMessageV2) {
        let previousMessage = renderedMessage
        let reusableIDs = reusableViewIDs(from: previousMessage, to: message)
        if previousMessage?.id != message.id {
            cancelAvatarTask()
        }
        renderedMessage = message

        let framesByID = Dictionary(uniqueKeysWithValues: message.layout.blockLayouts.map { ($0.id, $0.frame) })
        for id in Array(blockViews.keys) where !reusableIDs.contains(id) {
            removeBlockView(for: id)
        }
        for id in reusableIDs {
            blockViews[id]?.frame = framesByID[id] ?? .zero
        }

        if let sender = message.sender,
           let avatarFrame = framesByID[MessageRenderCoordinatorV2.avatarLayoutID(for: message.id)],
           blockViews[MessageRenderCoordinatorV2.avatarLayoutID(for: message.id)] == nil {
            let avatarView = makeAvatarView(sender, frame: avatarFrame)
            contentView.addSubview(avatarView)
            blockViews[MessageRenderCoordinatorV2.avatarLayoutID(for: message.id)] = avatarView
        }
        if let sender = message.sender,
           sender.showsName,
           let senderFrame = framesByID[MessageRenderCoordinatorV2.senderLayoutID(for: message.id)],
           blockViews[MessageRenderCoordinatorV2.senderLayoutID(for: message.id)] == nil {
            let senderView = makeSenderView(sender, frame: senderFrame)
            contentView.addSubview(senderView)
            blockViews[MessageRenderCoordinatorV2.senderLayoutID(for: message.id)] = senderView
        }
        for block in message.blocks {
            guard let frame = framesByID[block.id], blockViews[block.id] == nil else { continue }
            let blockView = makeBlockView(
                for: block,
                frame: frame,
                isOutgoing: message.isOutgoing,
                renderArtifacts: message.renderArtifacts
            )
            contentView.addSubview(blockView)
            blockViews[block.id] = blockView
        }
        if let status = message.status,
           !status.displayText.isEmpty,
           let statusFrame = framesByID[MessageRenderCoordinatorV2.statusLayoutID(for: message.id)],
           blockViews[MessageRenderCoordinatorV2.statusLayoutID(for: message.id)] == nil {
            let statusView = makeStatusView(status, frame: statusFrame, isOutgoing: message.isOutgoing)
            contentView.addSubview(statusView)
            blockViews[MessageRenderCoordinatorV2.statusLayoutID(for: message.id)] = statusView
        }

        accessibilityIdentifier = "chatRoomV2.message.\(message.id)"
        accessibilityLabel = message.text
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributes
    }

    private func configureViews() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        clipsToBounds = false
        contentView.clipsToBounds = false
    }

    private func makeBlockView(
        for block: MessageBlockContentV2,
        frame: CGRect,
        isOutgoing: Bool,
        renderArtifacts: MessageRenderArtifactsV2
    ) -> UIView {
        switch block {
        case .text(let text):
            return makeTextBlock(
                text,
                artifact: renderArtifacts.text(for: text.id),
                frame: frame,
                isOutgoing: isOutgoing
            )
        case .code(let code):
            return makeCodeBlock(
                code,
                artifact: renderArtifacts.code(for: code.id),
                frame: frame,
                isOutgoing: isOutgoing
            )
        case .table(let table):
            return makeTableBlock(
                table,
                artifact: renderArtifacts.table(for: table.id),
                frame: frame,
                isOutgoing: isOutgoing
            )
        case .image(let image):
            return makeImageBlock(image, frame: frame)
        case .audio(let audio):
            return makeAudioBlock(audio, frame: frame, isOutgoing: isOutgoing)
        case .document(let document):
            return makeDocumentBlock(document, frame: frame, isOutgoing: isOutgoing)
        }
    }

    private func makeTextBlock(
        _ block: TextBlockContentV2,
        artifact: TextBlockRenderArtifactV2?,
        frame: CGRect,
        isOutgoing: Bool
    ) -> UIView {
        let bubbleView = textBlockViewPool.popLast() ?? ReusableTextMessageBlockViewV2()
        bubbleView.frame = frame
        bubbleView.accessibilityIdentifier = block.id
        bubbleView.isAccessibilityElement = false
        bubbleView.accessibilityLabel = block.text
        bubbleView.backgroundColor = isOutgoing ? UIColor.systemBlue : UIColor.secondarySystemBackground
        bubbleView.layer.cornerRadius = 18
        bubbleView.layer.cornerCurve = .continuous
        bubbleView.clipsToBounds = true

        let textView = bubbleView.textView
        textView.frame = bubbleView.bounds.insetBy(dx: 12, dy: 10)
        textView.accessibilityIdentifier = "chatRoomV2.text.\(block.id)"
        textView.isAccessibilityElement = true
        textView.linkTextAttributes = [
            .foregroundColor: isOutgoing ? UIColor.white : UIColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        textView.attributedText = artifact?.attributedText ?? MessageTextFormatterV2.attributedString(
            for: block.text,
            isOutgoing: isOutgoing,
            rendersMarkdown: block.isMarkdown
        )
        return bubbleView
    }

    private func makeDocumentBlock(_ block: DocumentLinkBlockContentV2, frame: CGRect, isOutgoing: Bool) -> UIView {
        let container = UIView(frame: frame)
        container.accessibilityIdentifier = block.id
        container.isAccessibilityElement = false
        container.backgroundColor = isOutgoing ? UIColor.systemBlue : UIColor.secondarySystemBackground
        container.layer.cornerRadius = 16
        container.layer.cornerCurve = .continuous
        container.layer.borderWidth = 1
        container.layer.borderColor = (isOutgoing ? UIColor.white.withAlphaComponent(0.18) : UIColor.separator.withAlphaComponent(0.35)).cgColor
        container.clipsToBounds = true

        let actionHeight: CGFloat = 44
        let openHeight = max(1, frame.height - actionHeight)
        let horizontalInset: CGFloat = 12

        let openControl = UIControl(frame: CGRect(x: 0, y: 0, width: frame.width, height: openHeight))
        openControl.accessibilityIdentifier = "\(block.id).open"
        openControl.isAccessibilityElement = true
        openControl.accessibilityLabel = L10n.t("打开文档 \(block.preview.title)", "Open document \(block.preview.title)")
        openControl.accessibilityTraits.insert(.button)
        openControl.addAction(UIAction { [weak self] _ in
            self?.onDocumentTap?(block.preview.id)
        }, for: .touchUpInside)
        container.addSubview(openControl)

        let iconContainer = UIView(frame: CGRect(x: horizontalInset, y: 14, width: 40, height: 40))
        iconContainer.backgroundColor = isOutgoing ? UIColor.white.withAlphaComponent(0.16) : UIColor.systemBlue.withAlphaComponent(0.11)
        iconContainer.layer.cornerRadius = 10
        iconContainer.layer.cornerCurve = .continuous
        iconContainer.isUserInteractionEnabled = false
        let iconView = UIImageView(image: UIImage(systemName: "doc.text"))
        iconView.tintColor = isOutgoing ? .white : .systemBlue
        iconView.contentMode = .scaleAspectFit
        iconView.frame = CGRect(x: 10, y: 10, width: 20, height: 20)
        iconContainer.addSubview(iconView)
        openControl.addSubview(iconContainer)

        let textX = iconContainer.frame.maxX + 10
        let textWidth = max(1, frame.width - textX - horizontalInset - 14)

        let titleLabel = UILabel(frame: CGRect(x: textX, y: 12, width: textWidth, height: 40))
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = isOutgoing ? .white : UIColor.label
        titleLabel.text = block.preview.title
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isUserInteractionEnabled = false
        openControl.addSubview(titleLabel)

        let metadataLabel = UILabel(frame: CGRect(x: textX, y: 58, width: textWidth, height: 16))
        metadataLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        metadataLabel.textColor = isOutgoing ? UIColor.white.withAlphaComponent(0.72) : .secondaryLabel
        metadataLabel.text = "\(block.preview.documentType) · \(block.preview.updatedLabel)"
        metadataLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.isUserInteractionEnabled = false
        openControl.addSubview(metadataLabel)

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = isOutgoing ? UIColor.white.withAlphaComponent(0.58) : .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.frame = CGRect(x: frame.width - horizontalInset - 10, y: 28, width: 10, height: 14)
        chevron.isUserInteractionEnabled = false
        openControl.addSubview(chevron)

        let subtitleLabel = UILabel(frame: CGRect(x: horizontalInset, y: 84, width: max(1, frame.width - horizontalInset * 2), height: 38))
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = isOutgoing ? UIColor.white.withAlphaComponent(0.78) : .secondaryLabel
        subtitleLabel.text = block.preview.summary
        subtitleLabel.numberOfLines = 2
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.isUserInteractionEnabled = false
        openControl.addSubview(subtitleLabel)

        let separator = UIView(frame: CGRect(x: horizontalInset, y: openHeight, width: frame.width - horizontalInset * 2, height: 0.5))
        separator.backgroundColor = isOutgoing ? UIColor.white.withAlphaComponent(0.18) : UIColor.separator.withAlphaComponent(0.28)
        container.addSubview(separator)

        let actionTop = openHeight
        let buttonWidth = (frame.width - horizontalInset * 2 - 42 - 16) / 2
        let actions = [
            ("text.bubble", "继续修改", { [weak self] in self?.onDocumentContinueTap?(block.preview) }),
            ("arrow.up.right", "打开", { [weak self] in self?.onDocumentTap?(block.preview.id) })
        ]
        for (index, action) in actions.enumerated() {
            let button = UIButton(type: .system)
            button.frame = CGRect(
                x: horizontalInset + CGFloat(index) * (buttonWidth + 8),
                y: actionTop + 6,
                width: buttonWidth,
                height: 32
            )
            button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
            button.setTitle(" \(action.1)", for: .normal)
            button.setImage(UIImage(systemName: action.0), for: .normal)
            button.accessibilityIdentifier = "\(block.id).\(index == 0 ? "continue" : "openAction")"
            button.accessibilityLabel = index == 0 ? "继续修改文档" : "打开文档"
            button.tintColor = isOutgoing ? .white : .systemBlue
            button.backgroundColor = isOutgoing ? UIColor.white.withAlphaComponent(0.08) : UIColor.systemBackground.withAlphaComponent(0.72)
            button.layer.cornerRadius = 8
            button.layer.cornerCurve = .continuous
            button.addAction(UIAction { _ in action.2() }, for: .touchUpInside)
            container.addSubview(button)
        }

        let shareView = UIImageView(image: UIImage(systemName: "link"))
        shareView.tintColor = isOutgoing ? UIColor.white.withAlphaComponent(0.5) : .tertiaryLabel
        shareView.contentMode = .center
        shareView.frame = CGRect(x: frame.width - horizontalInset - 36, y: actionTop + 6, width: 36, height: 32)
        shareView.backgroundColor = isOutgoing ? UIColor.white.withAlphaComponent(0.08) : UIColor.systemBackground.withAlphaComponent(0.72)
        shareView.layer.cornerRadius = 8
        shareView.layer.cornerCurve = .continuous
        shareView.isAccessibilityElement = true
        shareView.accessibilityLabel = "分享即将支持"
        container.addSubview(shareView)

        return container
    }

    private func makeCodeBlock(
        _ block: CodeBlockContentV2,
        artifact: CodeBlockRenderArtifactV2?,
        frame: CGRect,
        isOutgoing: Bool
    ) -> UIView {
        let container = UIView(frame: frame)
        container.accessibilityIdentifier = block.id
        container.isAccessibilityElement = false
        container.accessibilityLabel = block.code
        container.backgroundColor = ChatCodeSyntaxHighlighterV2.backgroundColor(isOutgoing: isOutgoing, userInterfaceStyle: traitCollection.userInterfaceStyle)
        container.layer.cornerRadius = 12
        container.layer.cornerCurve = .continuous
        container.clipsToBounds = true

        let headerHeight: CGFloat = block.language == nil ? 0 : 28
        if let language = block.language {
            let languageLabel = UILabel(frame: CGRect(x: 12, y: 7, width: max(1, frame.width - 24), height: 14))
            languageLabel.accessibilityIdentifier = "\(block.id).language"
            languageLabel.isAccessibilityElement = true
            languageLabel.autoresizingMask = [.flexibleWidth]
            languageLabel.font = .systemFont(ofSize: 10, weight: .semibold)
            languageLabel.textColor = ChatCodeSyntaxHighlighterV2.headerColor(isOutgoing: isOutgoing, userInterfaceStyle: traitCollection.userInterfaceStyle)
            languageLabel.text = language.uppercased()
            container.addSubview(languageLabel)
        }

        let scrollFrame = CGRect(
            x: 12,
            y: headerHeight + 6,
            width: max(1, frame.width - 24),
            height: max(1, frame.height - headerHeight - 14)
        )
        let scrollView = UIScrollView(frame: scrollFrame)
        scrollView.accessibilityIdentifier = "\(block.id).scroll"
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.backgroundColor = .clear

        let contentWidth = max(
            scrollFrame.width,
            (artifact?.contentWidth ?? ChatCodeSyntaxHighlighterV2.contentWidth(for: block.code)) + 1
        )
        let label = UILabel(frame: CGRect(x: 0, y: 0, width: contentWidth, height: scrollFrame.height))
        label.accessibilityIdentifier = "\(block.id).content"
        label.isAccessibilityElement = true
        label.accessibilityLabel = block.code
        label.numberOfLines = 0
        label.lineBreakMode = .byClipping
        label.attributedText = artifact?.plainAttributedText ?? ChatCodeSyntaxHighlighterV2.plainAttributedString(
            for: block.code,
            isOutgoing: isOutgoing,
            userInterfaceStyle: traitCollection.userInterfaceStyle
        )
        scrollView.contentSize = CGSize(width: contentWidth, height: scrollFrame.height)
        scrollView.addSubview(label)
        container.addSubview(scrollView)

        let interfaceStyle = traitCollection.userInterfaceStyle
        codeTasks[block.id] = Task { [weak self, weak label, weak container] in
            let highlighted = await ChatCodeSyntaxHighlighterV2.highlightedAttributedString(
                for: block.code,
                language: block.language,
                isOutgoing: isOutgoing,
                userInterfaceStyle: interfaceStyle
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      let container,
                      self.blockViews[block.id] === container,
                      self.renderedMessage?.blocks.contains(.code(block)) == true
                else {
                    return
                }
                label?.attributedText = highlighted
            }
        }
        return container
    }

    private func makeTableBlock(
        _ block: TableBlockContentV2,
        artifact: TableBlockRenderArtifactV2?,
        frame: CGRect,
        isOutgoing: Bool
    ) -> UIView {
        let container = UIView(frame: frame)
        container.accessibilityIdentifier = block.id
        container.isAccessibilityElement = false
        container.accessibilityLabel = block.copyableText
        container.backgroundColor = isOutgoing ? UIColor.systemBlue.withAlphaComponent(0.95) : UIColor.secondarySystemBackground
        container.layer.cornerRadius = 12
        container.layer.cornerCurve = .continuous
        container.layer.borderWidth = isOutgoing ? 0 : 0.5
        container.layer.borderColor = UIColor.separator.withAlphaComponent(0.42).cgColor
        container.clipsToBounds = true

        let fallbackMetrics = artifact == nil ? ChatTableLayoutMetricsV2.metrics(for: block) : nil
        let columnWidths = artifact?.columnWidths ?? fallbackMetrics?.columnWidths ?? []
        let contentWidth = artifact?.contentWidth ?? fallbackMetrics?.contentWidth ?? frame.width
        let contentHeight = artifact?.contentHeight ?? fallbackMetrics?.contentHeight ?? frame.height
        let scrollView = UIScrollView(frame: container.bounds)
        scrollView.accessibilityIdentifier = "\(block.id).scroll"
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = false
        scrollView.backgroundColor = .clear

        let contentView = UIView(frame: CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight))
        contentView.backgroundColor = .clear
        scrollView.contentSize = contentView.bounds.size
        scrollView.addSubview(contentView)

        var y: CGFloat = 0
        for (rowIndex, row) in block.rows.enumerated() {
            let rowHeight = rowIndex == 0 ? ChatTableLayoutMetricsV2.headerHeight : ChatTableLayoutMetricsV2.rowHeight
            let rowBackground = UIView(frame: CGRect(x: 0, y: y, width: contentWidth, height: rowHeight))
            rowBackground.backgroundColor = rowIndex == 0
                ? (isOutgoing ? UIColor.white.withAlphaComponent(0.14) : UIColor.tertiarySystemFill)
                : .clear
            contentView.addSubview(rowBackground)

            var x: CGFloat = 0
            for column in 0..<columnWidths.count {
                let width = columnWidths[column]
                let value = column < row.count ? row[column] : ""
                let label = UILabel(frame: CGRect(x: x + 10, y: y + 7, width: max(1, width - 20), height: max(1, rowHeight - 14)))
                label.accessibilityIdentifier = "\(block.id).r\(rowIndex)c\(column)"
                label.isAccessibilityElement = true
                label.accessibilityLabel = value
                label.font = rowIndex == 0 ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 13)
                label.textColor = isOutgoing ? .white : .label
                label.numberOfLines = 2
                label.lineBreakMode = .byTruncatingTail
                label.text = value
                contentView.addSubview(label)

                if column > 0 {
                    let verticalRule = UIView(frame: CGRect(x: x, y: y, width: 0.5, height: rowHeight))
                    verticalRule.backgroundColor = isOutgoing ? UIColor.white.withAlphaComponent(0.22) : UIColor.separator.withAlphaComponent(0.42)
                    contentView.addSubview(verticalRule)
                }
                x += width
            }

            if rowIndex < block.rows.count - 1 {
                let horizontalRule = UIView(frame: CGRect(x: 0, y: y + rowHeight - 0.5, width: contentWidth, height: 0.5))
                horizontalRule.backgroundColor = isOutgoing ? UIColor.white.withAlphaComponent(0.22) : UIColor.separator.withAlphaComponent(0.42)
                contentView.addSubview(horizontalRule)
            }
            y += rowHeight
        }

        container.addSubview(scrollView)
        return container
    }

    private func makeAvatarView(_ sender: MessageSenderPresentationV2, frame: CGRect) -> UIView {
        let container = UIView(frame: frame)
        container.accessibilityIdentifier = "chatRoomV2.avatar.\(sender.displayName)"
        container.isAccessibilityElement = true
        container.accessibilityLabel = sender.displayName
        container.layer.cornerRadius = frame.width / 2
        container.clipsToBounds = true
        container.backgroundColor = sender.isBot ? UIColor.systemBlue.withAlphaComponent(0.16) : UIColor.tertiarySystemFill

        let fallbackLabel = UILabel(frame: container.bounds)
        fallbackLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        fallbackLabel.textAlignment = .center
        fallbackLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        fallbackLabel.textColor = sender.isBot ? .systemBlue : .secondaryLabel
        fallbackLabel.text = sender.isBot ? "⌘" : initials(for: sender.displayName)
        container.addSubview(fallbackLabel)

        let imageView = UIImageView(frame: container.bounds)
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        container.addSubview(imageView)
        loadAvatar(for: sender, into: imageView)
        return container
    }

    private func makeSenderView(_ sender: MessageSenderPresentationV2, frame: CGRect) -> UIView {
        let label = UILabel(frame: frame)
        label.accessibilityIdentifier = "chatRoomV2.sender.\(sender.displayName)"
        label.isAccessibilityElement = true
        label.accessibilityLabel = sender.displayName
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabel
        label.text = sender.isBot ? "\(sender.displayName)  BOT" : sender.displayName
        return label
    }

    private func makeImageBlock(_ block: ImageBlockContentV2, frame: CGRect) -> UIView {
        let container = UIButton(type: .custom)
        container.frame = frame
        container.accessibilityIdentifier = block.id
        container.isAccessibilityElement = true
        container.accessibilityLabel = block.name
        container.accessibilityTraits.insert(.button)
        container.layer.cornerRadius = block.isSticker ? 18 : 20
        container.layer.cornerCurve = .continuous
        container.clipsToBounds = true
        container.backgroundColor = UIColor.secondarySystemBackground
        container.addAction(UIAction { [weak self] _ in
            self?.onImageTap?(block.id)
        }, for: .touchUpInside)

        let imageView = UIImageView(frame: container.bounds)
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = UIColor.secondarySystemBackground
        imageView.isUserInteractionEnabled = false
        container.addSubview(imageView)

        let placeholder = UILabel(frame: container.bounds.insetBy(dx: 12, dy: 12))
        placeholder.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        placeholder.textAlignment = .center
        placeholder.numberOfLines = 2
        placeholder.font = .systemFont(ofSize: 13, weight: .medium)
        placeholder.textColor = .secondaryLabel
        placeholder.text = block.urlString?.isEmpty == false ? "图片加载中..." : "图片不可用"
        placeholder.isUserInteractionEnabled = false
        container.addSubview(placeholder)

        loadImage(for: block, into: imageView, placeholder: placeholder)
        return container
    }

    private func makeAudioBlock(_ block: AudioBlockContentV2, frame: CGRect, isOutgoing: Bool) -> UIView {
        let button = UIButton(type: .system)
        button.frame = frame
        button.accessibilityIdentifier = block.id
        button.layer.cornerRadius = 18
        button.layer.cornerCurve = .continuous
        button.clipsToBounds = true
        button.backgroundColor = isOutgoing ? UIColor.systemBlue : UIColor.secondarySystemBackground
        button.tintColor = isOutgoing ? .white : .systemBlue
        button.contentHorizontalAlignment = isOutgoing ? .right : .left
        button.accessibilityLabel = "播放语音消息"

        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "play.fill")
        configuration.imagePadding = 10
        configuration.baseForegroundColor = isOutgoing ? .white : .systemBlue
        configuration.attributedTitle = AttributedString(block.durationLabel, attributes: AttributeContainer([
            .font: UIFont.systemFont(ofSize: 13, weight: .medium)
        ]))
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 13, bottom: 9, trailing: 13)
        button.configuration = configuration
        let loadingIndicator = UIActivityIndicatorView(style: .medium)
        loadingIndicator.color = isOutgoing ? .white : .systemBlue
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(loadingIndicator)
        var indicatorConstraints = [
            loadingIndicator.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ]
        if isOutgoing {
            indicatorConstraints.append(loadingIndicator.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -13))
        } else {
            indicatorConstraints.append(loadingIndicator.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 13))
        }
        NSLayoutConstraint.activate(indicatorConstraints)
        audioLoadingViews[block.id] = loadingIndicator
        button.addAction(UIAction { [weak self, weak button] _ in
            self?.toggleAudio(block, button: button)
        }, for: .touchUpInside)
        audioObservationIDs[block.id] = ChatAudioPlaybackCoordinatorV2.shared.addObserver { [weak self, weak button, weak loadingIndicator] state in
            let isPlaying = state.playingBlockID == block.id
            let isLoading = state.loadingBlockID == block.id
            let didFail = state.failedBlockID == block.id
            self?.updateAudioButton(
                button,
                loadingIndicator: loadingIndicator,
                isPlaying: isPlaying,
                isLoading: isLoading,
                title: didFail ? "无法播放" : block.durationLabel
            )
        }
        return button
    }

    private func makeStatusView(_ status: MessageStatusPresentationV2, frame: CGRect, isOutgoing: Bool) -> UIView {
        let label = UILabel(frame: frame)
        label.accessibilityIdentifier = "chatRoomV2.status"
        label.isAccessibilityElement = true
        label.accessibilityLabel = status.displayText
        label.font = .systemFont(ofSize: 11)
        label.textAlignment = isOutgoing ? .right : .left
        label.textColor = .secondaryLabel
        label.text = status.displayText
        return label
    }

    private func loadImage(for block: ImageBlockContentV2, into imageView: UIImageView, placeholder: UILabel) {
        guard let urlString = block.urlString,
              !urlString.isEmpty,
              let url = APIClient.shared.resolvedURL(from: urlString)
        else {
            placeholder.text = "图片不可用"
            return
        }

        let targetPointSize = imageView.bounds.size
        let displayScale = max(traitCollection.displayScale, 1)
        let cacheContent = block.cacheContent
        let sourceIdentifier = cacheContent.mediaCacheSignatureV2.isEmpty
            ? url.absoluteString
            : cacheContent.mediaCacheSignatureV2
        if let cached = ChatImagePipelineV2.shared.cachedImage(
            sourceIdentifier: sourceIdentifier,
            targetPointSize: targetPointSize,
            scale: displayScale
        ) {
            imageView.image = cached
            placeholder.isHidden = true
            return
        }

        let requestID = UUID()
        imageRequestIDs[block.id] = requestID
        imageTasks[block.id] = Task { [weak self, weak imageView, weak placeholder] in
            let image = await ChatImagePipelineV2.shared.image(
                sourceIdentifier: sourceIdentifier,
                targetPointSize: targetPointSize,
                scale: displayScale,
                fallbackDataLoader: {
                    do {
                        let data = try await APIClient.shared.fetchRemoteData(
                            from: url,
                            acceptHeader: "image/*,*/*;q=0.8"
                        )
                        _ = await LocalImageStore.shared.cacheImageDataAsync(
                            data,
                            for: cacheContent,
                            fallbackIdentifier: block.id,
                            replacingExisting: true
                        )
                        return data
                    } catch {
                        return nil
                    }
                }
            ) {
                await LocalImageStore.shared.cachedImageData(
                    for: cacheContent,
                    fallbackIdentifier: block.id
                )
            }
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self,
                      self.imageRequestIDs[block.id] == requestID,
                      self.renderedMessage?.blocks.contains(.image(block)) == true,
                      let imageView,
                      let container = self.blockViews[block.id],
                      imageView.isDescendant(of: container)
                else {
                    return
                }

                if let image {
                    imageView.image = image
                    placeholder?.isHidden = true
                } else {
                    placeholder?.text = "图片不可用"
                }
                self.imageRequestIDs[block.id] = nil
                self.imageTasks[block.id] = nil
            }
        }
    }

    private func loadAvatar(for sender: MessageSenderPresentationV2, into imageView: UIImageView) {
        guard let urlString = sender.avatarURLString,
              let url = APIClient.shared.resolvedURL(from: urlString)
        else {
            return
        }

        guard let messageID = renderedMessage?.id else { return }
        let avatarLayoutID = MessageRenderCoordinatorV2.avatarLayoutID(for: messageID)
        if let cached = AvatarImageLoader.cachedImageForDisplay(for: url) {
            imageView.image = cached
            return
        }

        let requestID = UUID()
        avatarRequestID = requestID
        avatarTask = Task { [weak self, weak imageView] in
            let image = await AvatarImageLoader.imageForDisplay(for: url)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self,
                      self.avatarRequestID == requestID,
                      self.renderedMessage?.sender == sender,
                      let image,
                      let imageView,
                      let container = self.blockViews[avatarLayoutID],
                      imageView.isDescendant(of: container)
                else {
                    return
                }
                imageView.image = image
                self.avatarRequestID = nil
                self.avatarTask = nil
            }
        }
    }

    private func toggleAudio(_ block: AudioBlockContentV2, button: UIButton?) {
        ChatAudioPlaybackCoordinatorV2.shared.toggle(block: block)
    }

    private func updateAudioButton(
        _ button: UIButton?,
        loadingIndicator: UIActivityIndicatorView?,
        isPlaying: Bool,
        isLoading: Bool,
        title: String
    ) {
        var configuration = button?.configuration
        configuration?.image = isLoading ? nil : UIImage(systemName: isPlaying ? "pause.fill" : "play.fill")
        configuration?.attributedTitle = AttributedString(title, attributes: AttributeContainer([
            .font: UIFont.systemFont(ofSize: 13, weight: .medium)
        ]))
        button?.configuration = configuration
        if isLoading {
            loadingIndicator?.startAnimating()
        } else {
            loadingIndicator?.stopAnimating()
        }
        button?.accessibilityLabel = isLoading ? "语音加载中" : (isPlaying ? "暂停语音消息" : "播放语音消息")
    }

    private func removeAudioObservers() {
        audioObservationIDs.values.forEach { ChatAudioPlaybackCoordinatorV2.shared.removeObserver($0) }
        audioObservationIDs.removeAll()
        audioLoadingViews.values.forEach { $0.stopAnimating() }
        audioLoadingViews.removeAll()
    }

    private func removeAudioObserver(for blockID: String) {
        if let observationID = audioObservationIDs.removeValue(forKey: blockID) {
            ChatAudioPlaybackCoordinatorV2.shared.removeObserver(observationID)
        }
        audioLoadingViews.removeValue(forKey: blockID)?.stopAnimating()
    }

    private func reusableViewIDs(
        from previousMessage: RenderedMessageV2?,
        to message: RenderedMessageV2
    ) -> Set<String> {
        guard let previousMessage, previousMessage.id == message.id else { return [] }

        let previousFrames = Dictionary(uniqueKeysWithValues: previousMessage.layout.blockLayouts.map { ($0.id, $0.frame) })
        let nextFrames = Dictionary(uniqueKeysWithValues: message.layout.blockLayouts.map { ($0.id, $0.frame) })
        let previousBlocks = Dictionary(uniqueKeysWithValues: previousMessage.blocks.map { ($0.id, $0) })
        var reusableIDs: Set<String> = []

        for block in message.blocks {
            guard previousBlocks[block.id] == block,
                  previousMessage.isOutgoing == message.isOutgoing,
                  previousMessage.renderArtifacts.blocksByID[block.id] == message.renderArtifacts.blocksByID[block.id],
                  previousFrames[block.id]?.size == nextFrames[block.id]?.size,
                  nextFrames[block.id] != nil
            else {
                continue
            }
            if case .image = block, previousMessage.renderScale != message.renderScale {
                continue
            }
            reusableIDs.insert(block.id)
        }

        let avatarID = MessageRenderCoordinatorV2.avatarLayoutID(for: message.id)
        if previousMessage.sender == message.sender,
           previousMessage.renderScale == message.renderScale,
           previousFrames[avatarID]?.size == nextFrames[avatarID]?.size,
           nextFrames[avatarID] != nil {
            reusableIDs.insert(avatarID)
        }

        let senderID = MessageRenderCoordinatorV2.senderLayoutID(for: message.id)
        if previousMessage.sender == message.sender,
           previousFrames[senderID] != nil,
           nextFrames[senderID] != nil {
            reusableIDs.insert(senderID)
        }

        let statusID = MessageRenderCoordinatorV2.statusLayoutID(for: message.id)
        if previousMessage.status == message.status,
           previousMessage.isOutgoing == message.isOutgoing,
           previousFrames[statusID] != nil,
           nextFrames[statusID] != nil {
            reusableIDs.insert(statusID)
        }

        return reusableIDs
    }

    private func removeBlockView(for id: String) {
        imageTasks.removeValue(forKey: id)?.cancel()
        imageRequestIDs[id] = nil
        codeTasks.removeValue(forKey: id)?.cancel()
        removeAudioObserver(for: id)

        if let messageID = renderedMessage?.id,
           id == MessageRenderCoordinatorV2.avatarLayoutID(for: messageID) {
            cancelAvatarTask()
        }
        guard let view = blockViews.removeValue(forKey: id) else { return }
        view.removeFromSuperview()
        recycleTextBlockViewIfNeeded(view)
    }

    private func resetRenderedContent() {
        cancelImageTasks()
        cancelCodeTasks()
        cancelAvatarTask()
        removeAudioObservers()
        blockViews.values.forEach { view in
            view.removeFromSuperview()
            recycleTextBlockViewIfNeeded(view)
        }
        blockViews.removeAll()
    }

    private func recycleTextBlockViewIfNeeded(_ view: UIView) {
        guard let textView = view as? ReusableTextMessageBlockViewV2 else { return }
        textView.prepareForPool()
        if textBlockViewPool.count < 8 {
            textBlockViewPool.append(textView)
        }
    }

    private func cancelImageTasks() {
        imageTasks.values.forEach { $0.cancel() }
        imageTasks.removeAll()
        imageRequestIDs.removeAll()
    }

    private func cancelCodeTasks() {
        codeTasks.values.forEach { $0.cancel() }
        codeTasks.removeAll()
    }

    private func cancelAvatarTask() {
        avatarTask?.cancel()
        avatarTask = nil
        avatarRequestID = nil
    }

    private func initials(for name: String) -> String {
        let words = name
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .map(String.init)
        let characters = words.prefix(2).compactMap(\.first)
        if !characters.isEmpty {
            return characters.map { String($0) }.joined().uppercased()
        }
        return name.first.map { String($0).uppercased() } ?? "?"
    }

    deinit {
        resetRenderedContent()
    }
}

private final class ReusableTextMessageBlockViewV2: UIView {
    let textView: UITextView

    init() {
        textView = UITextView(frame: .zero)
        super.init(frame: .zero)

        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        clipsToBounds = true

        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = true
        textView.isAccessibilityElement = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = false
        textView.dataDetectorTypes = []
        addSubview(textView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func prepareForPool() {
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        backgroundColor = .clear
        textView.attributedText = nil
        textView.accessibilityIdentifier = nil
        textView.linkTextAttributes = [:]
    }
}

enum ChatCodeSyntaxHighlighterV2 {
    static func plainAttributedString(for code: String, isOutgoing: Bool, userInterfaceStyle: UIUserInterfaceStyle) -> NSAttributedString {
        normalizedCodeAttributedString(
            NSMutableAttributedString(string: code.isEmpty ? " " : code),
            isOutgoing: isOutgoing,
            userInterfaceStyle: userInterfaceStyle
        )
    }

    static func highlightedAttributedString(
        for code: String,
        language: String?,
        isOutgoing: Bool,
        userInterfaceStyle: UIUserInterfaceStyle
    ) async -> NSAttributedString {
        let key = "\(paletteKey(isOutgoing: isOutgoing, userInterfaceStyle: userInterfaceStyle))::\(language?.lowercased() ?? "auto")::\(code)"
        if let cached = cachedHighlight(for: key) {
            return cached
        }

        do {
            let highlighter = Highlight()
            let colors = HighlightColors.custom(css: css(isOutgoing: isOutgoing, userInterfaceStyle: userInterfaceStyle))
            let highlighted: AttributedString
            if let normalizedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines), !normalizedLanguage.isEmpty {
                highlighted = try await highlighter.attributedText(code, language: normalizedLanguage, colors: colors)
            } else {
                highlighted = try await highlighter.attributedText(code, colors: colors)
            }
            let normalized = normalizedCodeAttributedString(
                NSMutableAttributedString(highlighted),
                isOutgoing: isOutgoing,
                userInterfaceStyle: userInterfaceStyle
            )
            cacheHighlight(normalized, for: key)
            return normalized
        } catch {
            return plainAttributedString(for: code, isOutgoing: isOutgoing, userInterfaceStyle: userInterfaceStyle)
        }
    }

    static func contentWidth(for code: String) -> CGFloat {
        let font = codeFont
        let lines = code.components(separatedBy: .newlines)
        let widest = lines.map { line in
            (line.isEmpty ? " " : line) as NSString
        }.map { line in
            line.size(withAttributes: [.font: font]).width
        }.max() ?? 1
        return ceil(widest)
    }

    static func backgroundColor(isOutgoing: Bool, userInterfaceStyle: UIUserInterfaceStyle) -> UIColor {
        if isOutgoing {
            return UIColor(red: 0.08, green: 0.18, blue: 0.34, alpha: 1)
        }
        return userInterfaceStyle == .dark
            ? UIColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1)
            : UIColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1)
    }

    static func headerColor(isOutgoing: Bool, userInterfaceStyle: UIUserInterfaceStyle) -> UIColor {
        if isOutgoing {
            return UIColor.white.withAlphaComponent(0.7)
        }
        return userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.62) : .secondaryLabel
    }

    private static let codeFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let lineSpacing: CGFloat = 3

    private static func normalizedCodeAttributedString(
        _ attributed: NSMutableAttributedString,
        isOutgoing: Bool,
        userInterfaceStyle: UIUserInterfaceStyle
    ) -> NSAttributedString {
        guard attributed.length > 0 else {
            return NSAttributedString(string: " ", attributes: baseCodeAttributes(isOutgoing: isOutgoing, userInterfaceStyle: userInterfaceStyle))
        }

        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: fullRange) { attributes, range, _ in
            var nextAttributes: [NSAttributedString.Key: Any] = [
                .font: codeFont,
                .paragraphStyle: codeParagraphStyle
            ]
            if attributes[.foregroundColor] == nil {
                nextAttributes[.foregroundColor] = baseCodeColor(isOutgoing: isOutgoing, userInterfaceStyle: userInterfaceStyle)
            }
            attributed.addAttributes(nextAttributes, range: range)
        }
        return attributed
    }

    private static func baseCodeAttributes(isOutgoing: Bool, userInterfaceStyle: UIUserInterfaceStyle) -> [NSAttributedString.Key: Any] {
        [
            .font: codeFont,
            .foregroundColor: baseCodeColor(isOutgoing: isOutgoing, userInterfaceStyle: userInterfaceStyle),
            .paragraphStyle: codeParagraphStyle
        ]
    }

    private static var codeParagraphStyle: NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byClipping
        return paragraph
    }

    private static func baseCodeColor(isOutgoing: Bool, userInterfaceStyle: UIUserInterfaceStyle) -> UIColor {
        if isOutgoing {
            return UIColor(red: 0.94, green: 0.97, blue: 1, alpha: 1)
        }
        return userInterfaceStyle == .dark ? UIColor(red: 0.88, green: 0.92, blue: 0.97, alpha: 1) : UIColor(red: 0.08, green: 0.11, blue: 0.16, alpha: 1)
    }

    @MainActor
    private static var highlightCache: [String: NSAttributedString] = [:]

    @MainActor
    private static var highlightCacheOrder: [String] = []

    private static let highlightCacheLimit = 80

    @MainActor
    private static func cachedHighlight(for key: String) -> NSAttributedString? {
        highlightCache[key]
    }

    @MainActor
    private static func cacheHighlight(_ value: NSAttributedString, for key: String) {
        if highlightCache[key] == nil {
            highlightCacheOrder.append(key)
        }
        highlightCache[key] = value
        while highlightCacheOrder.count > highlightCacheLimit {
            let oldestKey = highlightCacheOrder.removeFirst()
            highlightCache[oldestKey] = nil
        }
    }

    private static func paletteKey(isOutgoing: Bool, userInterfaceStyle: UIUserInterfaceStyle) -> String {
        isOutgoing ? "sent" : (userInterfaceStyle == .dark ? "received-dark" : "received-light")
    }

    private static func css(isOutgoing: Bool, userInterfaceStyle: UIUserInterfaceStyle) -> String {
        if isOutgoing {
            return sentCodeCSS
        }
        return userInterfaceStyle == .dark ? receivedDarkCodeCSS : receivedCodeCSS
    }

    private static let sentCodeCSS = """
    .hljs { color: #f8fafc; }
    .hljs-comment, .hljs-quote { color: #94a3b8; }
    .hljs-keyword, .hljs-selector-tag, .hljs-literal { color: #fde047; }
    .hljs-string, .hljs-doctag, .hljs-regexp { color: #86efac; }
    .hljs-number, .hljs-symbol, .hljs-bullet { color: #c4b5fd; }
    .hljs-title, .hljs-section, .hljs-function .hljs-title { color: #7dd3fc; }
    .hljs-type, .hljs-class .hljs-title, .hljs-built_in { color: #fda4af; }
    .hljs-meta, .hljs-meta .hljs-keyword, .hljs-selector-id { color: #fdba74; }
    .hljs-attr, .hljs-attribute, .hljs-property { color: #67e8f9; }
    """

    private static let receivedCodeCSS = """
    .hljs { color: #0f172a; }
    .hljs-comment, .hljs-quote { color: #64748b; }
    .hljs-keyword, .hljs-selector-tag, .hljs-literal { color: #7c3aed; }
    .hljs-string, .hljs-doctag, .hljs-regexp { color: #16a34a; }
    .hljs-number, .hljs-symbol, .hljs-bullet { color: #ea580c; }
    .hljs-title, .hljs-section, .hljs-function .hljs-title { color: #2563eb; }
    .hljs-type, .hljs-class .hljs-title, .hljs-built_in { color: #0891b2; }
    .hljs-meta, .hljs-meta .hljs-keyword, .hljs-selector-id { color: #dc2626; }
    .hljs-attr, .hljs-attribute, .hljs-property { color: #0f766e; }
    """

    private static let receivedDarkCodeCSS = """
    .hljs { color: #e2e8f0; }
    .hljs-comment, .hljs-quote { color: #94a3b8; }
    .hljs-keyword, .hljs-selector-tag, .hljs-literal { color: #c4b5fd; }
    .hljs-string, .hljs-doctag, .hljs-regexp { color: #86efac; }
    .hljs-number, .hljs-symbol, .hljs-bullet { color: #fdba74; }
    .hljs-title, .hljs-section, .hljs-function .hljs-title { color: #7dd3fc; }
    .hljs-type, .hljs-class .hljs-title, .hljs-built_in { color: #fda4af; }
    .hljs-meta, .hljs-meta .hljs-keyword, .hljs-selector-id { color: #f87171; }
    .hljs-attr, .hljs-attribute, .hljs-property { color: #67e8f9; }
    """
}

enum ChatTableLayoutMetricsV2 {
    struct Metrics: Equatable {
        let columnWidths: [CGFloat]
        let contentWidth: CGFloat
        let contentHeight: CGFloat
    }

    static let headerHeight: CGFloat = 40
    static let rowHeight: CGFloat = 38

    static func metrics(for table: TableBlockContentV2) -> Metrics {
        let columnCount = max(table.columnCount, 1)
        let widths = (0..<columnCount).map { column in
            let widest = table.rows.enumerated().map { rowIndex, row in
                column < row.count ? textWidth(row[column], isHeader: rowIndex == 0) : 0
            }.max() ?? 0
            return min(max(72, ceil(widest + 24)), 184)
        }
        let contentWidth = max(120, widths.reduce(0, +))
        let contentHeight = headerHeight + CGFloat(max(0, table.rows.count - 1)) * rowHeight
        return Metrics(
            columnWidths: widths,
            contentWidth: contentWidth,
            contentHeight: max(headerHeight, contentHeight)
        )
    }

    private static func textWidth(_ text: String, isHeader: Bool) -> CGFloat {
        let font = isHeader ? UIFont.systemFont(ofSize: 13, weight: .semibold) : UIFont.systemFont(ofSize: 13)
        let measured = ((text.isEmpty ? " " : text) as NSString).boundingRect(
            with: CGSize(width: 220, height: 36),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return ceil(measured.width)
    }
}

import HighlightSwift
import UIKit

final class TextMessageCollectionViewCell: UICollectionViewCell {
    static let reuseIdentifier = "TextMessageCollectionViewCell"

    private static let imageCache = NSCache<NSString, UIImage>()
    private static let avatarCache = NSCache<NSString, UIImage>()

    private var renderedMessage: RenderedMessageV2?
    private var blockViews: [String: UIView] = [:]
    private var imageTasks: [String: Task<Void, Never>] = [:]
    private var codeTasks: [String: Task<Void, Never>] = [:]
    private var avatarTask: Task<Void, Never>?
    private var audioObservationIDs: [String: UUID] = [:]
    private var audioLoadingViews: [String: UIActivityIndicatorView] = [:]

    var onImageTap: ((String) -> Void)?

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
        cancelImageTasks()
        cancelCodeTasks()
        cancelAvatarTask()
        removeAudioObservers()
        renderedMessage = nil
        onImageTap = nil
        blockViews.values.forEach { $0.removeFromSuperview() }
        blockViews.removeAll()
    }

    func configure(with message: RenderedMessageV2) {
        renderedMessage = message
        cancelImageTasks()
        cancelCodeTasks()
        cancelAvatarTask()
        blockViews.values.forEach { $0.removeFromSuperview() }
        blockViews.removeAll()

        let framesByID = Dictionary(uniqueKeysWithValues: message.layout.blockLayouts.map { ($0.id, $0.frame) })
        if let sender = message.sender,
           let avatarFrame = framesByID[MessageRenderCoordinatorV2.avatarLayoutID(for: message.id)] {
            let avatarView = makeAvatarView(sender, frame: avatarFrame)
            contentView.addSubview(avatarView)
            blockViews[MessageRenderCoordinatorV2.avatarLayoutID(for: message.id)] = avatarView
        }
        if let sender = message.sender,
           sender.showsName,
           let senderFrame = framesByID[MessageRenderCoordinatorV2.senderLayoutID(for: message.id)] {
            let senderView = makeSenderView(sender, frame: senderFrame)
            contentView.addSubview(senderView)
            blockViews[MessageRenderCoordinatorV2.senderLayoutID(for: message.id)] = senderView
        }
        for block in message.blocks {
            guard let frame = framesByID[block.id] else { continue }
            let blockView = makeBlockView(for: block, frame: frame, isOutgoing: message.isOutgoing)
            contentView.addSubview(blockView)
            blockViews[block.id] = blockView
        }
        if let status = message.status,
           !status.displayText.isEmpty,
           let statusFrame = framesByID[MessageRenderCoordinatorV2.statusLayoutID(for: message.id)] {
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

    private func makeBlockView(for block: MessageBlockContentV2, frame: CGRect, isOutgoing: Bool) -> UIView {
        switch block {
        case .text(let text):
            return makeTextBlock(text, frame: frame, isOutgoing: isOutgoing)
        case .code(let code):
            return makeCodeBlock(code, frame: frame, isOutgoing: isOutgoing)
        case .table(let table):
            return makeTableBlock(table, frame: frame, isOutgoing: isOutgoing)
        case .image(let image):
            return makeImageBlock(image, frame: frame)
        case .audio(let audio):
            return makeAudioBlock(audio, frame: frame, isOutgoing: isOutgoing)
        }
    }

    private func makeTextBlock(_ block: TextBlockContentV2, frame: CGRect, isOutgoing: Bool) -> UIView {
        let bubbleView = UIView(frame: frame)
        bubbleView.accessibilityIdentifier = block.id
        bubbleView.isAccessibilityElement = false
        bubbleView.accessibilityLabel = block.text
        bubbleView.backgroundColor = isOutgoing ? UIColor.systemBlue : UIColor.secondarySystemBackground
        bubbleView.layer.cornerRadius = 18
        bubbleView.layer.cornerCurve = .continuous
        bubbleView.clipsToBounds = true

        let textView = UITextView(frame: bubbleView.bounds.insetBy(dx: 12, dy: 10))
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = false
        textView.dataDetectorTypes = [.link]
        textView.linkTextAttributes = [
            .foregroundColor: isOutgoing ? UIColor.white : UIColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        textView.attributedText = MessageTextFormatterV2.attributedString(
            for: block.text,
            isOutgoing: isOutgoing,
            rendersMarkdown: block.isMarkdown
        )
        bubbleView.addSubview(textView)
        return bubbleView
    }

    private func makeCodeBlock(_ block: CodeBlockContentV2, frame: CGRect, isOutgoing: Bool) -> UIView {
        let container = UIView(frame: frame)
        container.accessibilityIdentifier = block.id
        container.isAccessibilityElement = true
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

        let contentWidth = max(scrollFrame.width, ChatCodeSyntaxHighlighterV2.contentWidth(for: block.code) + 1)
        let label = UILabel(frame: CGRect(x: 0, y: 0, width: contentWidth, height: scrollFrame.height))
        label.accessibilityIdentifier = "\(block.id).content"
        label.isAccessibilityElement = true
        label.accessibilityLabel = block.code
        label.numberOfLines = 0
        label.lineBreakMode = .byClipping
        label.attributedText = ChatCodeSyntaxHighlighterV2.plainAttributedString(
            for: block.code,
            isOutgoing: isOutgoing,
            userInterfaceStyle: traitCollection.userInterfaceStyle
        )
        scrollView.contentSize = CGSize(width: contentWidth, height: scrollFrame.height)
        scrollView.addSubview(label)
        container.addSubview(scrollView)

        let interfaceStyle = traitCollection.userInterfaceStyle
        codeTasks[block.id] = Task { [weak self, weak label] in
            let highlighted = await ChatCodeSyntaxHighlighterV2.highlightedAttributedString(
                for: block.code,
                language: block.language,
                isOutgoing: isOutgoing,
                userInterfaceStyle: interfaceStyle
            )
            await MainActor.run {
                guard let self,
                      self.renderedMessage?.blocks.contains(where: { $0.id == block.id }) == true
                else {
                    return
                }
                label?.attributedText = highlighted
            }
        }
        return container
    }

    private func makeTableBlock(_ block: TableBlockContentV2, frame: CGRect, isOutgoing: Bool) -> UIView {
        let container = UIView(frame: frame)
        container.accessibilityIdentifier = block.id
        container.isAccessibilityElement = true
        container.accessibilityLabel = block.copyableText
        container.backgroundColor = isOutgoing ? UIColor.systemBlue.withAlphaComponent(0.95) : UIColor.secondarySystemBackground
        container.layer.cornerRadius = 12
        container.layer.cornerCurve = .continuous
        container.layer.borderWidth = isOutgoing ? 0 : 0.5
        container.layer.borderColor = UIColor.separator.withAlphaComponent(0.42).cgColor
        container.clipsToBounds = true

        let metrics = ChatTableLayoutMetricsV2.metrics(for: block)
        let scrollView = UIScrollView(frame: container.bounds)
        scrollView.accessibilityIdentifier = "\(block.id).scroll"
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = false
        scrollView.backgroundColor = .clear

        let contentView = UIView(frame: CGRect(x: 0, y: 0, width: metrics.contentWidth, height: metrics.contentHeight))
        contentView.backgroundColor = .clear
        scrollView.contentSize = contentView.bounds.size
        scrollView.addSubview(contentView)

        var y: CGFloat = 0
        for (rowIndex, row) in block.rows.enumerated() {
            let rowHeight = rowIndex == 0 ? ChatTableLayoutMetricsV2.headerHeight : ChatTableLayoutMetricsV2.rowHeight
            let rowBackground = UIView(frame: CGRect(x: 0, y: y, width: metrics.contentWidth, height: rowHeight))
            rowBackground.backgroundColor = rowIndex == 0
                ? (isOutgoing ? UIColor.white.withAlphaComponent(0.14) : UIColor.tertiarySystemFill)
                : .clear
            contentView.addSubview(rowBackground)

            var x: CGFloat = 0
            for column in 0..<metrics.columnWidths.count {
                let width = metrics.columnWidths[column]
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
                let horizontalRule = UIView(frame: CGRect(x: 0, y: y + rowHeight - 0.5, width: metrics.contentWidth, height: 0.5))
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
        label.textColor = status.isPending ? .systemOrange : .secondaryLabel
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

        let cacheKey = url.absoluteString as NSString
        if let cached = Self.imageCache.object(forKey: cacheKey) {
            imageView.image = cached
            placeholder.isHidden = true
            return
        }

        let cacheContent = block.cacheContent
        let cachedFileURL = LocalImageStore.shared.cachedFileURL(for: cacheContent, fallbackIdentifier: block.id)
        imageTasks[block.id] = Task { [weak imageView, weak placeholder] in
            if let cachedFileURL,
               let image = await Self.decodedImage(from: cachedFileURL) {
                Self.imageCache.setObject(image, forKey: cacheKey)
                await MainActor.run {
                    imageView?.image = image
                    placeholder?.isHidden = true
                }
                return
            }

            do {
                let data = try await APIClient.shared.fetchRemoteData(from: url, acceptHeader: "image/*,*/*;q=0.8")
                _ = LocalImageStore.shared.cacheImageData(data, for: cacheContent, fallbackIdentifier: block.id)
                guard let image = await Self.decodedImage(from: data) else {
                    await MainActor.run {
                        placeholder?.text = "图片不可用"
                    }
                    return
                }
                Self.imageCache.setObject(image, forKey: cacheKey)
                await MainActor.run {
                    imageView?.image = image
                    placeholder?.isHidden = true
                }
            } catch {
                await MainActor.run {
                    placeholder?.text = "图片不可用"
                }
            }
        }
    }

    private static func decodedImage(from data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            UIImage(data: data)
        }.value
    }

    private static func decodedImage(from fileURL: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: fileURL.path)
        }.value
    }

    private func loadAvatar(for sender: MessageSenderPresentationV2, into imageView: UIImageView) {
        guard let urlString = sender.avatarURLString,
              let url = APIClient.shared.resolvedURL(from: urlString)
        else {
            return
        }

        let cacheKey = url.absoluteString as NSString
        if let cached = Self.avatarCache.object(forKey: cacheKey) {
            imageView.image = cached
            return
        }

        avatarTask = Task { [weak imageView] in
            do {
                let data = try await APIClient.shared.fetchRemoteData(
                    from: url,
                    acceptHeader: "image/avif,image/webp,image/*,*/*;q=0.8"
                )
                guard let image = await Task.detached(priority: .userInitiated, operation: {
                    UIImage(data: data)
                }).value else {
                    return
                }
                Self.avatarCache.setObject(image, forKey: cacheKey)
                await MainActor.run {
                    imageView?.image = image
                }
            } catch {
                return
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

    private func cancelImageTasks() {
        imageTasks.values.forEach { $0.cancel() }
        imageTasks.removeAll()
    }

    private func cancelCodeTasks() {
        codeTasks.values.forEach { $0.cancel() }
        codeTasks.removeAll()
    }

    private func cancelAvatarTask() {
        avatarTask?.cancel()
        avatarTask = nil
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
        cancelImageTasks()
        cancelCodeTasks()
        cancelAvatarTask()
        removeAudioObservers()
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

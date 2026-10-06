import UIKit

/// A voice bubble owns its content geometry; UIButton.Configuration can defer
/// alignment until a later update, visibly shifting content after cell reuse.
final class ChatAudioMessageButtonV2: UIButton {
    let playbackIcon = UIImageView()
    let durationLabel = UILabel()
    let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let isOutgoing: Bool
    private let duration: String
    private let titleWidth: CGFloat

    init(frame: CGRect, isOutgoing: Bool, duration: String) {
        self.isOutgoing = isOutgoing
        self.duration = duration
        let font = UIFont.systemFont(ofSize: 13, weight: .medium)
        // Reserve the retry label from the start so error transitions do not
        // push the icon sideways on short outgoing recordings.
        titleWidth = ceil(max(
            (duration as NSString).size(withAttributes: [.font: font]).width,
            (L10n.t("重试", "Retry") as NSString).size(withAttributes: [.font: font]).width
        ))
        super.init(frame: frame)
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        clipsToBounds = true
        backgroundColor = isOutgoing ? .chatOutgoing : .chatIncoming
        let color: UIColor = isOutgoing ? .white : .systemBlue
        playbackIcon.tintColor = color
        playbackIcon.contentMode = .scaleAspectFit
        durationLabel.textColor = color
        durationLabel.font = font
        durationLabel.numberOfLines = 1
        durationLabel.lineBreakMode = .byTruncatingTail
        loadingIndicator.color = color
        loadingIndicator.hidesWhenStopped = true
        let contentViews: [UIView] = [playbackIcon, durationLabel, loadingIndicator]
        for view in contentViews {
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            addSubview(view)
        }
        isAccessibilityElement = true
        accessibilityTraits = .button
        update(isPlaying: false, isLoading: false, didFail: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.65 : 1 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let iconSize: CGFloat = 22
        let gap: CGFloat = 10
        let textWidth = min(titleWidth, max(0, bounds.width - 26 - iconSize - gap))
        let contentWidth = iconSize + gap + textWidth
        let x = isOutgoing ? bounds.width - 13 - contentWidth : 13
        playbackIcon.frame = CGRect(x: x, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        loadingIndicator.frame = playbackIcon.frame
        durationLabel.frame = CGRect(x: x + iconSize + gap, y: (bounds.height - 20) / 2, width: textWidth, height: 20)
    }

    func update(isPlaying: Bool, isLoading: Bool, didFail: Bool) {
        playbackIcon.image = UIImage(systemName: isPlaying ? "stop.fill" : "play.fill")
        playbackIcon.isHidden = isLoading
        durationLabel.text = didFail ? L10n.t("重试", "Retry") : duration
        if isLoading {
            loadingIndicator.startAnimating()
            accessibilityLabel = L10n.t("取消加载语音", "Cancel voice loading")
            accessibilityValue = L10n.t("加载中", "Loading")
        } else {
            loadingIndicator.stopAnimating()
            if isPlaying {
                accessibilityLabel = L10n.t("停止语音消息", "Stop voice message")
                accessibilityValue = L10n.t("播放中", "Playing")
            } else if didFail {
                accessibilityLabel = L10n.t("重试播放语音", "Retry voice message")
                accessibilityValue = L10n.t("无法播放", "Unable to play")
            } else {
                accessibilityLabel = L10n.t("播放语音消息", "Play voice message")
                accessibilityValue = L10n.t("未播放", "Not playing")
            }
        }
        setNeedsLayout()
    }
}

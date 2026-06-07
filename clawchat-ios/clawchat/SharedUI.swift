import Combine
import CryptoKit
import SwiftUI
import UIKit
import WebKit

struct PrimaryButton<Label: View>: View {
    let isLoading: Bool
    let action: () -> Void
    private let label: Label

    @Environment(\.isEnabled) private var isEnabled

    private var canSubmit: Bool {
        isEnabled && !isLoading
    }

    init(
        isLoading: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.isLoading = isLoading
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                label
                    .opacity(isLoading ? 0 : 1)

                if isLoading {
                    ProgressView()
                        .tint(.white)
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .padding(.horizontal, UITheme.Spacing.medium)
            .foregroundStyle(.white)
            .background(canSubmit ? Color.rcmsAccent : Color.rcmsOffline)
            .clipShape(RoundedRectangle(cornerRadius: UITheme.Radius.medium, style: .continuous))
            .shadow(color: canSubmit ? UITheme.Shadow.accentColor : .clear, radius: 10, x: 0, y: 5)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

struct PrimaryButtonLabel: View {
    let title: String
    let systemImage: String?

    var body: some View {
        HStack(spacing: UITheme.Spacing.tight) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.headline.weight(.semibold))
            }

            Text(title)
                .lineLimit(1)
        }
    }
}

extension PrimaryButton where Label == PrimaryButtonLabel {
    init(
        _ title: String,
        systemImage: String? = nil,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(isLoading: isLoading, action: action) {
            PrimaryButtonLabel(title: title, systemImage: systemImage)
        }
    }
}

struct StatusCard<Content: View>: View {
    let title: String
    let message: String?
    let systemImage: String
    let tint: Color
    private let content: Content

    init(
        title: String,
        message: String? = nil,
        systemImage: String = "info.circle.fill",
        tint: Color = .rcmsAccent,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UITheme.Spacing.medium) {
            HStack(alignment: .top, spacing: UITheme.Spacing.small) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.rcmsTextStrong)

                    if let message, !message.isEmpty {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(Color.rcmsTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }

            content
        }
        .padding(UITheme.Spacing.medium)
        .glassCardStyle()
    }
}

extension StatusCard where Content == EmptyView {
    init(
        title: String,
        message: String? = nil,
        systemImage: String = "info.circle.fill",
        tint: Color = .rcmsAccent
    ) {
        self.init(title: title, message: message, systemImage: systemImage, tint: tint) {
            EmptyView()
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let caption: String?
    let systemImage: String?
    let tint: Color

    init(
        title: String,
        value: String,
        caption: String? = nil,
        systemImage: String? = nil,
        tint: Color = .rcmsAccent
    ) {
        self.title = title
        self.value = value
        self.caption = caption
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(tint.opacity(0.12), in: Circle())
            }

            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Color.rcmsTextStrong)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.rcmsTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
                .frame(height: 16, alignment: .topLeading)

            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(Color.rcmsTextSecondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
        .padding(14)
        .glassCardStyle()
    }
}

struct AvatarBadge: View {
    let name: String
    let imageURL: String?
    let systemImage: String?
    let diameter: CGFloat
    let statusColor: Color?

    init(
        name: String,
        imageURL: String? = nil,
        systemImage: String? = nil,
        diameter: CGFloat = 44,
        statusColor: Color? = nil
    ) {
        self.name = name
        self.imageURL = imageURL
        self.systemImage = systemImage
        self.diameter = diameter
        self.statusColor = statusColor
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            avatarBody
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.rcmsAvatarBorder, lineWidth: 1))

            if let statusColor {
                Circle()
                    .fill(statusColor)
                    .frame(width: max(10, diameter * 0.22), height: max(10, diameter * 0.22))
                    .overlay(Circle().stroke(Color.rcmsSurfaceSolid, lineWidth: max(2, diameter * 0.045)))
            }
        }
        .frame(width: diameter, height: diameter)
    }

    @ViewBuilder
    private var avatarBody: some View {
        if let url = APIClient.shared.resolvedURL(from: imageURL) {
            RemoteAvatarImage(url: url) {
                fallbackAvatar
            }
        } else {
            fallbackAvatar
        }
    }

    private var fallbackAvatar: some View {
        ZStack {
            UITheme.avatarGradient

            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: diameter * 0.42, weight: .semibold))
                    .foregroundStyle(Color.rcmsAccent)
            } else {
                Text(initials)
                    .font(.system(size: diameter * 0.34, weight: .bold))
                    .foregroundStyle(Color.rcmsAccent)
            }
        }
    }

    private var initials: String {
        let words = name
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .map(String.init)

        let characters = words.prefix(2).compactMap { $0.first }
        if !characters.isEmpty {
            return characters.map { String($0) }.joined().uppercased()
        }

        return name.first.map { String($0).uppercased() } ?? "?"
    }
}

struct RemoteAvatarImage<Placeholder: View>: View {
    let url: URL
    @ViewBuilder let placeholder: () -> Placeholder
    @StateObject private var loader = AvatarImageLoader()

    var body: some View {
        Group {
            if let image = loader.visibleImage(for: url) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await loader.load(url: url)
        }
    }
}

struct AvatarImagePrefetcher {
    static func prefetch(_ urls: [URL]) {
        Task { @MainActor in
            AvatarImageLoader.prefetch(urls)
        }
    }
}

@MainActor
final class AvatarImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var displayedURL: URL?

    private static let diskCache = AvatarImageDiskCache()
    private static let imageCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 600
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    private static var inFlightLoads: [URL: Task<UIImage?, Never>] = [:]
    private var currentURL: URL?

    func visibleImage(for url: URL) -> UIImage? {
        if displayedURL == url, let image {
            return image
        }
        return Self.cachedImage(for: url)
    }

    static func prefetch(_ urls: [URL]) {
        for url in Array(Set(urls)) {
            guard cachedImage(for: url) == nil else { continue }
            Task {
                _ = await image(for: url)
            }
        }
    }

    func load(url: URL) async {
        if currentURL != url {
            if let cachedImage = Self.cachedImage(for: url) {
                image = cachedImage
                displayedURL = url
            } else {
                image = nil
                displayedURL = nil
            }
        }
        currentURL = url

        if let loadedImage = await Self.image(for: url), currentURL == url {
            image = loadedImage
            displayedURL = url
        }
    }

    private static func cachedImage(for url: URL) -> UIImage? {
        if let image = imageCache.object(forKey: url as NSURL) {
            return image
        }

        guard let image = diskCache.image(for: url) else {
            return nil
        }

        imageCache.setObject(image, forKey: url as NSURL, cost: cacheCost(for: image))
        return image
    }

    private static func image(for url: URL) async -> UIImage? {
        if let cachedImage = cachedImage(for: url) {
            return cachedImage
        }

        if let task = inFlightLoads[url] {
            return await task.value
        }

        let task = Task { @MainActor in
            let loadedImage: UIImage?
            if url.pathExtension.caseInsensitiveCompare("svg") == .orderedSame {
                loadedImage = await SVGAvatarSnapshotter.shared.image(for: url)
            } else {
                loadedImage = await loadBitmapImage(for: url)
            }

            if let loadedImage {
                cache(loadedImage, for: url)
            }
            return loadedImage
        }

        inFlightLoads[url] = task
        let loadedImage = await task.value
        inFlightLoads[url] = nil
        return loadedImage
    }

    private static func loadBitmapImage(for url: URL) async -> UIImage? {
        do {
            let data = try await APIClient.shared.fetchRemoteData(
                from: url,
                acceptHeader: "image/avif,image/webp,image/*,*/*;q=0.8"
            )
            return UIImage(data: data)
        } catch {
            return nil
        }
    }

    private static func cache(_ image: UIImage, for url: URL) {
        imageCache.setObject(image, forKey: url as NSURL, cost: cacheCost(for: image))
        diskCache.store(image, for: url)
    }

    private static func cacheCost(for image: UIImage) -> Int {
        max(1, Int(image.size.width * image.size.height * image.scale * image.scale * 4))
    }
}

private final class AvatarImageDiskCache {
    private let fileManager: FileManager
    private let directoryURL: URL
    private let writeQueue = DispatchQueue(label: "site.changer.clawchat.avatar-image-disk-cache")

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let baseURL = (try? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory

        let cacheURL = baseURL
            .appendingPathComponent("clawchat", isDirectory: true)
            .appendingPathComponent("avatar-cache", isDirectory: true)

        if !fileManager.fileExists(atPath: cacheURL.path) {
            try? fileManager.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        }

        self.directoryURL = cacheURL
    }

    func image(for url: URL) -> UIImage? {
        let fileURL = storageFileURL(for: url)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return UIImage(contentsOfFile: fileURL.path)
    }

    func store(_ image: UIImage, for url: URL) {
        let fileURL = storageFileURL(for: url)
        writeQueue.async { [fileManager] in
            guard !fileManager.fileExists(atPath: fileURL.path),
                  let data = image.pngData()
            else {
                return
            }
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    private func storageFileURL(for url: URL) -> URL {
        directoryURL.appendingPathComponent("\(digest(url.absoluteString)).png", isDirectory: false)
    }

    private func digest(_ rawValue: String) -> String {
        let hash = SHA256.hash(data: Data(rawValue.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
private final class SVGAvatarSnapshotter: NSObject, WKNavigationDelegate {
    static let shared = SVGAvatarSnapshotter()

    private let renderSize = CGSize(width: 96, height: 96)
    private var continuations: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]

    func image(for url: URL) async -> UIImage? {
        let svgMarkup = await fetchSVGMarkup(for: url)
        let html = htmlDocument(for: url, svgMarkup: svgMarkup)
        let webView = makeWebView()

        await withCheckedContinuation { continuation in
            continuations[ObjectIdentifier(webView)] = continuation
            webView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
        }

        try? await Task.sleep(nanoseconds: 20_000_000)

        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: renderSize)
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true

        let webView = WKWebView(frame: CGRect(origin: .zero, size: renderSize), configuration: configuration)
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.backgroundColor = .clear
        webView.isUserInteractionEnabled = false
        return webView
    }

    private func fetchSVGMarkup(for url: URL) async -> String? {
        do {
            let data = try await APIClient.shared.fetchRemoteData(
                from: url,
                acceptHeader: "image/svg+xml,*/*;q=0.8"
            )
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func htmlDocument(for url: URL, svgMarkup: String?) -> String {
        let body: String
        if let svgMarkup {
            body = svgMarkup
        } else {
            body = "<img src=\"\(escaped(url.absoluteString))\">"
        }

        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: transparent; }
            body { display: flex; align-items: stretch; justify-content: stretch; }
            svg, img { width: 100%; height: 100%; object-fit: cover; display: block; }
          </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    private func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(webView)
    }

    private func finish(_ webView: WKWebView) {
        let key = ObjectIdentifier(webView)
        guard let continuation = continuations.removeValue(forKey: key) else {
            return
        }
        continuation.resume()
    }
}

struct DashboardConversationRow: View {
    let title: String
    let subtitle: String?
    let timestamp: String?
    let unreadCount: Int?
    let avatarURL: String?
    let systemImage: String
    let statusColor: Color?
    let isMuted: Bool

    init(
        title: String,
        subtitle: String? = nil,
        timestamp: String? = nil,
        unreadCount: Int? = nil,
        avatarURL: String? = nil,
        systemImage: String = "person.fill",
        statusColor: Color? = nil,
        isMuted: Bool = false
    ) {
        self.title = title
        self.subtitle = subtitle
        self.timestamp = timestamp
        self.unreadCount = unreadCount
        self.avatarURL = avatarURL
        self.systemImage = systemImage
        self.statusColor = statusColor
        self.isMuted = isMuted
    }

    var body: some View {
        HStack(spacing: UITheme.Spacing.small) {
            AvatarBadge(
                name: title,
                imageURL: avatarURL,
                systemImage: systemImage,
                diameter: 52,
                statusColor: statusColor
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: UITheme.Spacing.tight) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.rcmsTextStrong)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if let timestamp, !timestamp.isEmpty {
                        Text(timestamp)
                            .font(.caption2)
                            .foregroundStyle(Color.rcmsTextSecondary)
                    }
                }

                HStack(spacing: UITheme.Spacing.tight) {
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Color.rcmsTextSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.rcmsTextSecondary)
                    }

                    if let unreadCount, unreadCount > 0 {
                        Text(unreadText(for: unreadCount))
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .frame(minWidth: 20, minHeight: 20)
                            .padding(.horizontal, unreadCount > 9 ? 6 : 0)
                            .background(Color.rcmsDanger, in: Capsule())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func unreadText(for count: Int) -> String {
        count > 99 ? "99+" : String(count)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String?
    let footer: String?
    private let content: Content

    init(
        _ title: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.rcmsTextSecondary)
                    .padding(.leading, 4)
            }

            VStack(spacing: 0) {
                content
            }
            .glassCardStyle()

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(Color.rcmsTextSecondary)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct SettingsRow<Accessory: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    let iconTint: Color
    let value: String?
    let showsChevron: Bool
    let action: (() -> Void)?
    private let accessory: Accessory

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        iconTint: Color = .rcmsAccent,
        value: String? = nil,
        showsChevron: Bool = false,
        action: (() -> Void)? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.iconTint = iconTint
        self.value = value
        self.showsChevron = showsChevron
        self.action = action
        self.accessory = accessory()
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: UITheme.Spacing.small) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 30, height: 30)
                    .background(iconTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.rcmsTextPrimary)
                    .lineLimit(1)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.rcmsTextSecondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            if let value, !value.isEmpty {
                Text(value)
                    .font(.caption.bold())
                    .foregroundStyle(Color.rcmsAccent)
                    .lineLimit(1)
            }

            accessory

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Color.rcmsTextSecondary.opacity(0.5))
            }
        }
        .padding(UITheme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension SettingsRow where Accessory == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        iconTint: Color = .rcmsAccent,
        value: String? = nil,
        showsChevron: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            iconTint: iconTint,
            value: value,
            showsChevron: showsChevron,
            action: action
        ) {
            EmptyView()
        }
    }
}

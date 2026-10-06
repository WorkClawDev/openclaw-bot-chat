import SwiftUI
import QuickLook

struct ChatFilePreview: View {
    @Environment(\.dismiss) private var dismiss
    let file: FileBlockContentV2
    @State private var localURL: URL?
    @State private var temporaryDirectory: URL?
    @State private var textPreview: String?
    @State private var textPreviewIsTruncated = false
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            Group {
                if let localURL {
                    if let textPreview {
                        VStack(spacing: 0) {
                            if textPreviewIsTruncated {
                                Text(L10n.t("仅预览文件开头，分享可打开完整文件。", "Showing the beginning. Share to open the complete file."))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(12)
                            }
                            FileTextPreview(text: textPreview)
                        }
                    } else {
                        FileQuickLook(url: localURL)
                    }
                } else if let error {
                    ContentUnavailableView {
                        Label(L10n.t("无法打开文件", "Unable to open file"), systemImage: "doc.badge.ellipsis")
                    } description: {
                        Text(error)
                    } actions: {
                        Button(L10n.t("重试", "Retry")) { attempt += 1 }
                    }
                } else {
                    ProgressView(L10n.t("正在下载…", "Downloading…"))
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("完成", "Done")) { dismiss() }
                }
                if let localURL {
                    ToolbarItem(placement: .primaryAction) { ShareLink(item: localURL).accessibilityIdentifier("chat.file.share") }
                }
            }
        }
        .task(id: attempt) { await download() }
        .onDisappear { removeTemporaryFile() }
    }

    @MainActor private func download() async {
        let scope = AccountSession.shared.snapshot
        let api = APIClient.shared
        error = nil
        do {
            var source = file.urlString
            // Renew expired signed URLs through the authenticated asset endpoint.
            if let id = file.assetID, let uuid = UUID(uuidString: id) {
                let asset: Asset = try await api.requestValue("/api/v1/assets/file/\(uuid.uuidString.lowercased())")
                source = asset.preferredMediaURLString
            }
            guard let url = api.resolvedURL(from: source), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
                throw URLError(.badURL)
            }
            let (download, response) = try await URLSession.shared.download(from: url)
            defer { try? FileManager.default.removeItem(at: download) }
            try Task.checkCancellation()
            guard AccountSession.shared.isCurrent(scope) else { throw CancellationError() }
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            removeTemporaryFile()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-file-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            temporaryDirectory = directory
            let name = (file.name as NSString).lastPathComponent
            let destination = directory.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "attachment" : name)
            try FileManager.default.moveItem(at: download, to: destination)
            if ["txt", "md", "csv"].contains(destination.pathExtension.lowercased()) {
                let previewLimit = 256 * 1024
                let data = try await Task.detached(priority: .userInitiated) {
                    let handle = try FileHandle(forReadingFrom: destination)
                    defer { try? handle.close() }
                    return try handle.read(upToCount: previewLimit + 1) ?? Data()
                }.value
                try Task.checkCancellation()
                textPreviewIsTruncated = data.count > previewLimit
                let prefix = data.prefix(previewLimit)
                if prefix.starts(with: [0xFF, 0xFE]) || prefix.starts(with: [0xFE, 0xFF]) {
                    textPreview = String(data: prefix, encoding: .utf16)
                } else {
                    textPreview = String(decoding: prefix, as: UTF8.self)
                }
            }
            guard AccountSession.shared.isCurrent(scope) else { throw CancellationError() }
            localURL = destination
        } catch is CancellationError {
            removeTemporaryFile()
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func removeTemporaryFile() {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
        localURL = nil
        textPreview = nil
        textPreviewIsTruncated = false
    }
}

private struct FileTextPreview: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 14, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        view.textColor = .label
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "chat.file.text"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}

private struct FileQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            controller.reloadData()
        }
    }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

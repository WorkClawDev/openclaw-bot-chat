import Foundation
import CryptoKit

final class LocalImageStore {
    static let shared = LocalImageStore()

    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "site.changer.clawchat.local-image-store")
    private let directoryURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let baseURL = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory

        let clawchatURL = baseURL.appendingPathComponent("clawchat", isDirectory: true)
        let imageCacheURL = clawchatURL.appendingPathComponent("image-cache", isDirectory: true)

        if !fileManager.fileExists(atPath: imageCacheURL.path) {
            try? fileManager.createDirectory(at: imageCacheURL, withIntermediateDirectories: true)
        }

        self.directoryURL = imageCacheURL
    }

    func cachedFileURL(for message: Message) -> URL? {
        cachedFileURL(for: message.content, fallbackIdentifier: message.id)
    }

    func cachedFileURL(for content: MessageContent, fallbackIdentifier: String? = nil) -> URL? {
        guard let fileURL = storageFileURL(for: content, fallbackIdentifier: fallbackIdentifier) else {
            return nil
        }
        return fileManager.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    func cachedImageData(for content: MessageContent, fallbackIdentifier: String? = nil) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let fileURL = self.storageFileURL(
                    for: content,
                    fallbackIdentifier: fallbackIdentifier
                ), self.fileManager.fileExists(atPath: fileURL.path) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: try? Data(contentsOf: fileURL, options: [.mappedIfSafe]))
            }
        }
    }

    @discardableResult
    func cacheImageData(_ data: Data, for message: Message) -> URL? {
        cacheImageData(data, for: message.content, fallbackIdentifier: message.id)
    }

    @discardableResult
    func cacheImageData(_ data: Data, for asset: Asset, fallbackIdentifier: String? = nil) -> URL? {
        let content = MessageContent(
            type: "image",
            body: nil,
            url: asset.preferredImageURLString,
            name: asset.fileName,
            size: asset.size,
            meta: ["asset": asset.metaValue]
        )
        return cacheImageData(data, for: content, fallbackIdentifier: fallbackIdentifier)
    }

    @discardableResult
    func cacheImageData(_ data: Data, for content: MessageContent, fallbackIdentifier: String? = nil) -> URL? {
        guard !data.isEmpty else {
            return nil
        }

        guard let fileURL = storageFileURL(for: content, fallbackIdentifier: fallbackIdentifier) else {
            return nil
        }

        queue.sync {
            if fileManager.fileExists(atPath: fileURL.path) {
                return
            }
            try? data.write(to: fileURL, options: [.atomic])
        }

        return fileManager.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    @discardableResult
    func cacheImageDataAsync(
        _ data: Data,
        for content: MessageContent,
        fallbackIdentifier: String? = nil,
        replacingExisting: Bool = false
    ) async -> URL? {
        guard !data.isEmpty else { return nil }

        return await withCheckedContinuation { continuation in
            queue.async {
                guard let fileURL = self.storageFileURL(
                    for: content,
                    fallbackIdentifier: fallbackIdentifier
                ) else {
                    continuation.resume(returning: nil)
                    return
                }
                if replacingExisting || !self.fileManager.fileExists(atPath: fileURL.path) {
                    try? data.write(to: fileURL, options: [.atomic])
                }
                continuation.resume(
                    returning: self.fileManager.fileExists(atPath: fileURL.path) ? fileURL : nil
                )
            }
        }
    }

    func ensureCachedImage(for message: Message) async -> URL? {
        if let cached = cachedFileURL(for: message) {
            return cached
        }

        guard let remoteURL = APIClient.shared.resolvedURL(from: message.content.imageURLString)
        else {
            return nil
        }

        do {
            let data = try await APIClient.shared.fetchRemoteData(from: remoteURL, acceptHeader: "image/*,*/*;q=0.8")
            return cacheImageData(data, for: message)
        } catch {
            print("Failed to cache image locally: \(error.localizedDescription)")
            return nil
        }
    }

    private func storageFileURL(for content: MessageContent, fallbackIdentifier: String?) -> URL? {
        guard let cacheKey = cacheKey(for: content, fallbackIdentifier: fallbackIdentifier) else {
            return nil
        }
        let fileExtension = fileExtension(for: content)
        return directoryURL.appendingPathComponent("\(cacheKey).\(fileExtension)", isDirectory: false)
    }

    private func cacheKey(for content: MessageContent, fallbackIdentifier: String?) -> String? {
        if let asset = content.asset {
            if let assetID = normalized(asset.id) {
                return digest(assetID)
            }
            if let objectKey = normalized(asset.objectKey) {
                return digest(objectKey)
            }
        }

        if let imageURLString = normalized(content.imageURLString) {
            return digest(imageURLString)
        }

        if let fallbackIdentifier = normalized(fallbackIdentifier) {
            return digest(fallbackIdentifier)
        }

        return nil
    }

    private func fileExtension(for content: MessageContent) -> String {
        if let mimeType = normalized(content.asset?.mimeType) {
            switch mimeType {
            case "image/png":
                return "png"
            case "image/webp":
                return "webp"
            case "image/gif":
                return "gif"
            default:
                return "jpg"
            }
        }

        let fileName = normalized(content.asset?.fileName) ?? normalized(content.name)
        if let fileName {
            let pathExtension = URL(fileURLWithPath: fileName).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pathExtension.isEmpty {
                return pathExtension.lowercased()
            }
        }

        if let imageURLString = normalized(content.imageURLString),
           let imageURL = URL(string: imageURLString) {
            let pathExtension = imageURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pathExtension.isEmpty {
                return pathExtension.lowercased()
            }
        }

        return "jpg"
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func digest(_ rawValue: String) -> String {
        let hash = SHA256.hash(data: Data(rawValue.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

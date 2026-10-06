import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Raw values preserve the existing Settings preference.
enum ImageSendMode: String, CaseIterable, Hashable {
    case compressed = "Compressed"
    case balanced = "Balanced"
    case original = "Original"

    static let storageKey = "settings.imageUploadQuality"

    static func preference(_ rawValue: String?) -> Self {
        Self(rawValue: rawValue ?? "") ?? .compressed
    }

    var shortTitle: String {
        switch self {
        case .compressed: L10n.t("压缩", "Compressed")
        case .balanced: L10n.t("均衡", "Balanced")
        case .original: L10n.t("原图", "Original")
        }
    }

    var jpegQuality: CGFloat {
        switch self {
        case .compressed: 0.72
        case .balanced: 0.85
        case .original: 0.95
        }
    }

    var maximumPixelSize: Int? {
        switch self {
        case .compressed: 2000
        case .balanced: 3000
        case .original: nil
        }
    }
}

struct UploadImagePayload {
    let data: Data
    let fileName: String
    let mimeType: String
    let width: Int?
    let height: Int?
}

enum ImageUploadPreparation {
    /// Inspect the transferred bytes: Photos' preferred type may describe a different representation.
    static func prepare(data: Data, mode: ImageSendMode) throws -> UploadImagePayload {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw PreparationError.unreadable }

        let mimeType = type.preferredMIMEType?.lowercased() ?? ""
        // Never flatten animated GIFs. Supported originals retain their exact encoded bytes.
        if mimeType == "image/gif" || (mode == .original && supportedMimeTypes.contains(mimeType)) {
            return UploadImagePayload(data: data,
                                      fileName: "image-\(UUID().uuidString.lowercased()).\(type.preferredFilenameExtension ?? "jpg")",
                                      mimeType: mimeType, width: width, height: height)
        }

        let maximum = min(mode.maximumPixelSize ?? max(width, height), max(width, height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PreparationError.unreadable
        }
        let size = CGSize(width: thumbnail.width, height: thumbnail.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let flattened = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: thumbnail).draw(in: CGRect(origin: .zero, size: size))
        }
        guard let encoded = flattened.jpegData(compressionQuality: mode.jpegQuality) else {
            throw PreparationError.unreadable
        }
        return UploadImagePayload(data: encoded, fileName: "image-\(UUID().uuidString.lowercased()).jpg",
                                  mimeType: "image/jpeg", width: thumbnail.width, height: thumbnail.height)
    }

    private static let supportedMimeTypes: Set<String> = ["image/jpeg", "image/png", "image/webp", "image/gif"]

    private enum PreparationError: LocalizedError {
        case unreadable
        var errorDescription: String? {
            L10n.t("无法读取所选图片，请换一张后重试。", "Unable to read this image. Please choose another.")
        }
    }
}

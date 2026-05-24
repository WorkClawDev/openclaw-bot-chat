import Foundation
import SwiftUI
import PhotosUI
import UIKit

enum AvatarUploadError: LocalizedError {
    case unreadableImage
    case unsupportedImage
    case invalidUploadResponse

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "Could not read the selected image"
        case .unsupportedImage:
            return "Please choose a valid image"
        case .invalidUploadResponse:
            return "Avatar upload completed without a usable asset"
        }
    }
}

struct AvatarUploadService {
    private static let avatarSize = CGSize(width: 512, height: 512)
    private static let mimeType = "image/png"

    static func uploadAvatar(from item: PhotosPickerItem, fileNamePrefix: String) async throws -> String {
        let image = try await loadImage(from: item)
        return try await uploadAvatarImage(image, fileNamePrefix: fileNamePrefix)
    }

    static func loadImage(from item: PhotosPickerItem) async throws -> UIImage {
        guard let rawData = try await item.loadTransferable(type: Data.self), !rawData.isEmpty else {
            throw AvatarUploadError.unreadableImage
        }

        guard let image = UIImage(data: rawData) else {
            throw AvatarUploadError.unsupportedImage
        }

        return image
    }

    static func uploadAvatarImage(_ image: UIImage, fileNamePrefix: String) async throws -> String {
        guard let pngData = squarePNGData(from: image) else {
            throw AvatarUploadError.unsupportedImage
        }

        let preparedUpload = try await APIClient.shared.prepareImageUpload(
            fileName: avatarFileName(prefix: fileNamePrefix),
            contentType: mimeType,
            size: pngData.count,
            conversationID: nil
        )

        try await APIClient.shared.uploadImageData(pngData, with: preparedUpload.upload)

        let assetID = preparedUpload.asset.id ?? ""
        let objectKey = preparedUpload.asset.objectKey ?? ""
        guard !assetID.isEmpty, !objectKey.isEmpty else {
            throw AvatarUploadError.invalidUploadResponse
        }

        let asset = try await APIClient.shared.completeImageUpload(assetID: assetID, objectKey: objectKey)
        guard let completedAssetID = asset.id, !completedAssetID.isEmpty else {
            throw AvatarUploadError.invalidUploadResponse
        }

        return APIClient.shared.publicImageURL(assetID: completedAssetID).absoluteString
    }

    private static func squarePNGData(from image: UIImage) -> Data? {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return nil
        }

        let shortestSide = min(sourceSize.width, sourceSize.height)
        let sourceRect = CGRect(
            x: (sourceSize.width - shortestSide) / 2,
            y: (sourceSize.height - shortestSide) / 2,
            width: shortestSide,
            height: shortestSide
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: avatarSize, format: format)
        let renderedImage = renderer.image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(origin: .zero, size: avatarSize))
            let scale = avatarSize.width / shortestSide
            image.draw(in: CGRect(
                x: -sourceRect.minX * scale,
                y: -sourceRect.minY * scale,
                width: sourceSize.width * scale,
                height: sourceSize.height * scale
            ))
        }

        return renderedImage.pngData()
    }

    private static func avatarFileName(prefix: String) -> String {
        let cleanedPrefix = prefix
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9_-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        let safePrefix = cleanedPrefix.isEmpty ? "avatar" : cleanedPrefix
        return "\(safePrefix)-avatar-\(UUID().uuidString.lowercased()).png"
    }
}

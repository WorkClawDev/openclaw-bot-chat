import Foundation
import ImageIO
import UIKit

enum ChatImageDownsamplerV2 {
    nonisolated static func downsampledImage(
        from data: Data,
        targetPointSize: CGSize,
        scale: CGFloat
    ) async -> UIImage? {
        let targetPointSize = normalizedTargetPointSize(targetPointSize)
        let scale = max(scale, 1)
        return await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                downsampledImageSynchronously(
                    from: data,
                    targetPointSize: targetPointSize,
                    scale: scale
                )
            }
        }.value
    }

    nonisolated static func downsampledImageSynchronously(
        from data: Data,
        targetPointSize: CGSize,
        scale: CGFloat
    ) -> UIImage? {
        guard !data.isEmpty else { return nil }

        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let targetPointSize = normalizedTargetPointSize(targetPointSize)
        let maximumPixelDimension = max(
            1,
            Int(ceil(max(targetPointSize.width, targetPointSize.height) * max(scale, 1)))
        )
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }

        return UIImage(cgImage: thumbnail, scale: max(scale, 1), orientation: .up)
    }

    nonisolated static func memoryCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        let (cost, overflow) = cgImage.bytesPerRow.multipliedReportingOverflow(by: cgImage.height)
        return overflow ? Int.max : max(cost, 1)
    }

    nonisolated private static func normalizedTargetPointSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(size.width, 1), height: max(size.height, 1))
    }
}

@MainActor
final class ChatImagePipelineV2 {
    static let shared = ChatImagePipelineV2()

    private struct InFlightRequest {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<UIImage?, Never>]
    }

    private let cache = NSCache<NSString, UIImage>()
    private var inFlightRequests: [String: InFlightRequest] = [:]

    init(countLimit: Int = 160, totalCostLimit: Int = 64 * 1024 * 1024) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    func image(
        sourceIdentifier: String,
        targetPointSize: CGSize,
        scale: CGFloat,
        fallbackDataLoader: (() async -> Data?)? = nil,
        dataLoader: @escaping () async -> Data?
    ) async -> UIImage? {
        let key = cacheKey(
            sourceIdentifier: sourceIdentifier,
            targetPointSize: targetPointSize,
            scale: scale
        )
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        let requestID: UUID
        if let existing = inFlightRequests[key] {
            requestID = existing.id
        } else {
            requestID = UUID()
            let task: Task<Void, Never> = Task { [weak self] in
                guard !Task.isCancelled else {
                    self?.completeRequest(key: key, requestID: requestID, image: nil)
                    return
                }

                var image: UIImage?
                if let data = await dataLoader(), !Task.isCancelled {
                    image = await ChatImageDownsamplerV2.downsampledImage(
                        from: data,
                        targetPointSize: targetPointSize,
                        scale: scale
                    )
                }
                if image == nil, !Task.isCancelled,
                   let fallbackDataLoader,
                   let fallbackData = await fallbackDataLoader(),
                   !Task.isCancelled {
                    image = await ChatImageDownsamplerV2.downsampledImage(
                        from: fallbackData,
                        targetPointSize: targetPointSize,
                        scale: scale
                    )
                }
                guard !Task.isCancelled else {
                    self?.completeRequest(key: key, requestID: requestID, image: nil)
                    return
                }
                self?.completeRequest(key: key, requestID: requestID, image: image)
            }
            inFlightRequests[key] = InFlightRequest(
                id: requestID,
                task: task,
                waiters: [:]
            )
        }

        let waiterID = UUID()
        let pipeline = self
        return await withTaskCancellationHandler {
            await waitForImage(key: key, requestID: requestID, waiterID: waiterID)
        } onCancel: {
            Task { @MainActor in
                pipeline.cancelWaiter(key: key, requestID: requestID, waiterID: waiterID)
            }
        }
    }

    func cachedImage(
        sourceIdentifier: String,
        targetPointSize: CGSize,
        scale: CGFloat
    ) -> UIImage? {
        cache.object(forKey: cacheKey(
            sourceIdentifier: sourceIdentifier,
            targetPointSize: targetPointSize,
            scale: scale
        ) as NSString)
    }

    func removeAllCachedImages() {
        cache.removeAllObjects()
    }

    private func waitForImage(key: String, requestID: UUID, waiterID: UUID) async -> UIImage? {
        await withCheckedContinuation { continuation in
            guard var request = inFlightRequests[key], request.id == requestID else {
                continuation.resume(returning: cache.object(forKey: key as NSString))
                return
            }
            request.waiters[waiterID] = continuation
            inFlightRequests[key] = request

            if Task.isCancelled {
                cancelWaiter(key: key, requestID: requestID, waiterID: waiterID)
            }
        }
    }

    private func cancelWaiter(key: String, requestID: UUID, waiterID: UUID) {
        guard var request = inFlightRequests[key], request.id == requestID,
              let continuation = request.waiters.removeValue(forKey: waiterID) else {
            return
        }

        if request.waiters.isEmpty {
            inFlightRequests[key] = nil
            request.task.cancel()
        } else {
            inFlightRequests[key] = request
        }
        continuation.resume(returning: nil)
    }

    private func completeRequest(key: String, requestID: UUID, image: UIImage?) {
        guard let request = inFlightRequests[key], request.id == requestID else { return }
        inFlightRequests[key] = nil

        if let image {
            cache.setObject(
                image,
                forKey: key as NSString,
                cost: ChatImageDownsamplerV2.memoryCost(of: image)
            )
        }
        request.waiters.values.forEach { $0.resume(returning: image) }
    }

    private func cacheKey(
        sourceIdentifier: String,
        targetPointSize: CGSize,
        scale: CGFloat
    ) -> String {
        let normalizedScale = max(scale, 1)
        let pixelWidth = max(1, Int(ceil(targetPointSize.width * normalizedScale)))
        let pixelHeight = max(1, Int(ceil(targetPointSize.height * normalizedScale)))
        return "\(sourceIdentifier)|\(pixelWidth)x\(pixelHeight)"
    }
}

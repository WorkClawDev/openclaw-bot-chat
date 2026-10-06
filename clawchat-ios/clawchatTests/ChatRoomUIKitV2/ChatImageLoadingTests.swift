import Testing
import UIKit
@testable import clawchat

@MainActor
struct ChatImageLoadingTests {
    @Test(arguments: [CGFloat(320), 393, 768])
    func realCachedImageLoadsAsynchronouslyWithoutChangingGeometry(width: CGFloat) async throws {
        let (message, file) = try cachedImageMessage()
        defer { try? FileManager.default.removeItem(at: file) }
        let rendered = MessageRenderCoordinatorV2().render(message, containerWidth: width, traitCollection: .init(displayScale: 3))
        let cell = TextMessageCollectionViewCell(frame: CGRect(origin: .zero, size: rendered.layout.itemSize))
        cell.configure(with: rendered)
        cell.layoutIfNeeded()
        let button = try #require(cell.contentView.subviews.compactMap { $0 as? UIButton }.first)
        let imageView = try #require(button.subviews.compactMap { $0 as? UIImageView }.first)
        let frame = button.frame
        let innerFrame = imageView.frame
        // The main actor has not yielded: disk-cache decoding must not run here.
        #expect(imageView.image == nil)
        for _ in 0..<150 where imageView.image == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let image = try #require(imageView.image)
        #expect(image.cgImage?.width == 480)
        #expect(image.cgImage?.height == 640)
        #expect(button.accessibilityValue == L10n.t("图片已加载", "Image loaded"))
        #expect(button.frame == frame)
        #expect(imageView.frame == innerFrame)
        #expect(cell.bounds.size == rendered.layout.itemSize)
    }

    @Test func cancelledCachedLoadCannotFillAnOldCellAfterReuse() async throws {
        let (message, file) = try cachedImageMessage()
        defer { try? FileManager.default.removeItem(at: file) }
        let renderer = MessageRenderCoordinatorV2()
        let rendered = renderer.render(message, containerWidth: 393, traitCollection: .init())
        let cell = TextMessageCollectionViewCell(frame: CGRect(origin: .zero, size: rendered.layout.itemSize))
        cell.configure(with: rendered)
        let oldButton = try #require(cell.contentView.subviews.compactMap { $0 as? UIButton }.first)
        let oldImage = try #require(oldButton.subviews.compactMap { $0 as? UIImageView }.first)
        cell.prepareForReuse()
        let next = ChatMessageV2(id: "replacement", sequence: 2, text: "Next message", isOutgoing: false)
        cell.configure(with: renderer.render(next, containerWidth: 393, traitCollection: .init()))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(oldImage.image == nil)
        #expect(oldButton.superview == nil)
        #expect(!cell.contentView.subviews.contains { $0 is UIButton })
    }

    private func cachedImageMessage() throws -> (ChatMessageV2, URL) {
        let id = UUID().uuidString
        let block = ImageBlockContentV2(id: id, urlString: "fixture://unit-image/\(id).jpg",
                                       name: "fixture.jpg", aspectRatio: 0.75, isSticker: false)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 640), format: format).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 640))
        }
        let data = try #require(image.jpegData(compressionQuality: 0.9))
        let file = try #require(LocalImageStore.shared.cacheImageData(data, for: block.cacheContent, fallbackIdentifier: id))
        return (ChatMessageV2(id: id, sequence: 1, isOutgoing: false, blocks: [.image(block)]), file)
    }
}

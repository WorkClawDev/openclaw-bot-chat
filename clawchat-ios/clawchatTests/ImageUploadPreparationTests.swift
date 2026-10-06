import Testing
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import clawchat

@MainActor
struct ImageUploadPreparationTests {
    @Test func threeQualitiesProduceDifferentActualPixelsAndBytes() throws {
        let data = try encodedFixture(width: 4096, height: 3072, type: .png)
        let small = try ImageUploadPreparation.prepare(data: data, mode: .compressed)
        let balanced = try ImageUploadPreparation.prepare(data: data, mode: .balanced)
        let original = try ImageUploadPreparation.prepare(data: data, mode: .original)
        try assertEncodedMetadata(small, width: 2000, height: 1500, mime: "image/jpeg")
        try assertEncodedMetadata(balanced, width: 3000, height: 2250, mime: "image/jpeg")
        try assertEncodedMetadata(original, width: 4096, height: 3072, mime: "image/png")
        #expect(small.data.count < balanced.data.count)
        // A lossless palette PNG can be smaller than JPEG; original bytes stay authoritative.
        #expect(original.data == data)
    }

    @Test(arguments: ImageSendMode.allCases)
    func smallImagesAreNeverUpscaled(mode: ImageSendMode) throws {
        let data = try encodedFixture(width: 240, height: 180, type: .png)
        let payload = try ImageUploadPreparation.prepare(data: data, mode: mode)
        try assertEncodedMetadata(payload, width: 240, height: 180,
                                  mime: mode == .original ? "image/png" : "image/jpeg")
    }

    @Test(arguments: ImageSendMode.allCases)
    func animatedGIFKeepsAllFramesAndOriginalBytes(mode: ImageSendMode) throws {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        for color in [UIColor.red, .blue] {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
            }
            CGImageDestinationAddImage(destination, try #require(image.cgImage), nil)
        }
        #expect(CGImageDestinationFinalize(destination))
        let payload = try ImageUploadPreparation.prepare(data: data as Data, mode: mode)
        #expect(payload.data == data as Data)
        #expect(payload.mimeType == "image/gif")
        let source = try #require(CGImageSourceCreateWithData(payload.data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 2)
    }

    @Test func originalUnsupportedServerFormatFallsBackToFullSizeJPEG() throws {
        let data = try encodedFixture(width: 600, height: 450, type: .tiff)
        let payload = try ImageUploadPreparation.prepare(data: data, mode: .original)
        try assertEncodedMetadata(payload, width: 600, height: 450, mime: "image/jpeg")
        #expect(payload.data != data)
    }

    @Test func encodingAppliesOrientationAndMetadataMatchesUploadedPixels() throws {
        let data = try encodedFixture(width: 600, height: 300, type: .jpeg, orientation: 6)
        let original = try ImageUploadPreparation.prepare(data: data, mode: .original)
        #expect(original.data == data)
        try assertEncodedMetadata(original, width: 600, height: 300, mime: "image/jpeg")
        for mode in [ImageSendMode.compressed, .balanced] {
            try assertEncodedMetadata(ImageUploadPreparation.prepare(data: data, mode: mode),
                                      width: 300, height: 600, mime: "image/jpeg")
        }
    }

    @Test func transparentImageGetsWhiteJPEGBackground() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80), format: format).image { _ in }
        let payload = try ImageUploadPreparation.prepare(data: #require(image.pngData()), mode: .compressed)
        let source = try #require(CGImageSourceCreateWithData(payload.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                             bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(pixel.prefix(3).allSatisfy { $0 >= 250 })
    }

    @Test func emptyAndCorruptInputCannotProduceUploadPayload() {
        for data in [Data(), Data("not an image".utf8)] {
            #expect(throws: (any Error).self) { try ImageUploadPreparation.prepare(data: data, mode: .original) }
        }
    }

    @Test func settingsRawValuesMapToEveryModeAndUnknownDefaultsToCompressed() {
        for mode in ImageSendMode.allCases { #expect(ImageSendMode.preference(mode.rawValue) == mode) }
        #expect(ImageSendMode.preference(nil) == .compressed)
        #expect(ImageSendMode.preference("removed-option") == .compressed)
    }

    private func assertEncodedMetadata(_ payload: UploadImagePayload, width: Int, height: Int, mime: String) throws {
        let source = try #require(CGImageSourceCreateWithData(payload.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let type = try #require(CGImageSourceGetType(source))
        #expect(UTType(type as String)?.preferredMIMEType == mime)
        #expect(payload.mimeType == mime)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == width)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == height)
        #expect(payload.width == width)
        #expect(payload.height == height)
    }

    private func encodedFixture(width: Int, height: Int, type: UTType, orientation: Int = 1) throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            for y in stride(from: 0, to: height, by: 16) {
                for x in stride(from: 0, to: width, by: 16) {
                    let seed = (x / 16 &* 73 + y / 16 &* 137) % 256
                    UIColor(red: CGFloat(seed) / 255, green: CGFloat((seed * 53) % 256) / 255,
                            blue: CGFloat((seed * 97) % 256) / 255, alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 16, height: 16))
                }
            }
        }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(image.cgImage), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

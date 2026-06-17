import Foundation
import ImageIO
import Testing
import UIKit

@testable import darkmatter_ios

@MainActor
struct MessageMediaThumbnailDecoderTests {
    @Test func decoderDownsamplesLargeImages() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80))
        let sourceImage = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        let data = try #require(sourceImage.pngData())

        let decoded = await MessageMediaThumbnailDecoder.image(data: data, maxPixelSize: 24, scale: 1)

        let image = try #require(decoded)
        #expect(max(image.size.width * image.scale, image.size.height * image.scale) <= 24)
    }

    @Test func decoderFailsClosedWhenImageIOSourceCreationFails() throws {
        let data = try sampleImageData()
        #expect(UIImage(data: data) != nil)

        var createThumbnailCalled = false
        let decoded = MessageMediaThumbnailDecoder.decodeThumbnailImage(
            data: data,
            targetPixelSize: 24,
            imageScale: 1,
            createSource: { _, _ in nil },
            createThumbnail: { _, _ in
                createThumbnailCalled = true
                return nil
            }
        )

        #expect(decoded == nil)
        #expect(!createThumbnailCalled)
    }

    @Test func decoderFailsClosedWhenImageIOThumbnailCreationFails() throws {
        let data = try sampleImageData()
        #expect(UIImage(data: data) != nil)

        var thumbnailMaxPixelSize: Int?
        let decoded = MessageMediaThumbnailDecoder.decodeThumbnailImage(
            data: data,
            targetPixelSize: 24,
            imageScale: 1,
            createSource: { data, options in
                CGImageSourceCreateWithData(data as CFData, options)
            },
            createThumbnail: { _, options in
                thumbnailMaxPixelSize = (options as NSDictionary)[kCGImageSourceThumbnailMaxPixelSize] as? Int
                return nil
            }
        )

        #expect(decoded == nil)
        #expect(thumbnailMaxPixelSize == 24)
    }

    @Test func thumbnailCacheCostIncludesDecodedBitmapAndSourceBytes() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 7))
        let image = renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 7))
        }
        let sourceData = Data(repeating: 0x7f, count: 13)
        let cgImage = try #require(image.cgImage)
        let expectedCost = cgImage.bytesPerRow * cgImage.height + sourceData.count

        #expect(MessageMediaThumbnailDecoder.thumbnailCacheCost(for: image, sourceData: sourceData) == expectedCost)
    }

    private func sampleImageData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 20))
        let image = renderer.image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 20))
        }
        return try #require(image.pngData())
    }
}

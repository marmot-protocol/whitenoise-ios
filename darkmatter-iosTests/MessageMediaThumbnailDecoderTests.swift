import Foundation
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

    @Test func decoderDoesNotUseUnboundedUIImageDataFallbacks() throws {
        let source = try decoderSource()

        #expect(source.contains("CGImageSourceCreateThumbnailAtIndex"))
        #expect(source.contains("kCGImageSourceThumbnailMaxPixelSize"))
        #expect(source.contains("kCGImageSourceShouldCache: false"))
        #expect(!source.contains("UIImage(data: data)"))
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

    private func decoderSource() throws -> String {
        let source = try messageBubbleSource()
        let start = try #require(source.range(of: "enum MessageMediaThumbnailDecoder {"))
        let end = try #require(source.range(of: "\nstruct MessageMediaGallery", range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func messageBubbleSource() throws -> String {
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent("darkmatter-ios/Conversation/MessageBubble.swift"),
            encoding: .utf8
        )
    }
}

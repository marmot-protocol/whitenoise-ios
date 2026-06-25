import Testing
import UIKit
@testable import whitenoise_ios

/// Camera portraits arrive as landscape sensor bitmaps tagged `.right`.
/// `MediaDraftProcessor` must bake the rotation into the encoded JPEG and
/// report `dim` in display orientation, or every downstream surface shows
/// the photo squashed.
@MainActor
struct MediaDraftProcessorOrientationTests {

    /// 400x100 landscape bitmap, left half red and right half blue. Tagged
    /// `.right` it displays as a 100x400 portrait with red on top.
    private func cameraStylePortrait() throws -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: 400, height: 100)
        let bitmap = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 200, y: 0, width: 200, height: 100))
        }
        let cgImage = try #require(bitmap.cgImage)
        return UIImage(cgImage: cgImage, scale: 1, orientation: .right)
    }

    @Test func cameraPortraitKeepsDisplayAspectInDimAndEncodedPixels() throws {
        let attachment = try MediaDraftProcessor.attachment(
            from: cameraStylePortrait(),
            fileName: nil
        )

        #expect(attachment.dim == "100x400")

        let decoded = try #require(UIImage(data: attachment.data))
        let pixels = try #require(decoded.cgImage)
        #expect(pixels.width == 100)
        #expect(pixels.height == 400)
        #expect(decoded.imageOrientation == .up)
    }

    @Test func cameraPortraitContentIsRotatedNotSquashed() throws {
        let attachment = try MediaDraftProcessor.attachment(
            from: cameraStylePortrait(),
            fileName: nil
        )
        let decoded = try #require(UIImage(data: attachment.data))

        let top = try #require(averageColor(of: decoded, sampleY: 100))
        let bottom = try #require(averageColor(of: decoded, sampleY: 300))
        #expect(top.red > top.blue, "top of the portrait should be the red half")
        #expect(bottom.blue > bottom.red, "bottom of the portrait should be the blue half")
    }

    @Test func upOrientedImagePassesThroughWithSameAspect() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let landscape = UIGraphicsImageRenderer(
            size: CGSize(width: 320, height: 240),
            format: format
        ).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        }

        let attachment = try MediaDraftProcessor.attachment(from: landscape, fileName: nil)
        #expect(attachment.dim == "320x240")
    }

    @Test func oversizedOrientedImageScalesLongEdgeToCap() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let bitmap = UIGraphicsImageRenderer(
            size: CGSize(width: 4096, height: 2048),
            format: format
        ).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4096, height: 2048))
        }
        let cgImage = try #require(bitmap.cgImage)
        let oriented = UIImage(cgImage: cgImage, scale: 1, orientation: .right)

        let attachment = try MediaDraftProcessor.attachment(from: oriented, fileName: nil)
        #expect(attachment.dim == "1024x2048")
    }

    @Test func attachmentCarriesPrecomputedThumbnail() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 640, height: 320),
            format: format
        ).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 320))
        }

        let attachment = try MediaDraftProcessor.attachment(from: image, fileName: nil)
        let thumbnail = try #require(attachment.thumbnail)
        let largestPixelEdge = max(
            thumbnail.size.width * thumbnail.scale,
            thumbnail.size.height * thumbnail.scale
        )

        #expect(largestPixelEdge <= MediaDraftProcessor.draftThumbnailPixelSize)
    }

    @Test func asyncAttachmentPreparationKeepsImageProcessingSemantics() async throws {
        let attachment = try await MediaDraftProcessor.preparedAttachment(
            from: cameraStylePortrait(),
            fileName: "portrait.heic"
        )

        #expect(attachment.fileName == "portrait.heic.jpg")
        #expect(attachment.mediaType == "image/jpeg")
        #expect(attachment.dim == "100x400")
        #expect(attachment.thumbnail != nil)
    }

    @Test func mediaDraftStripRendersPrecomputedThumbnail() throws {
        let source = try String(contentsOf: mediaComposerViewsSourceURL, encoding: .utf8)

        #expect(source.contains("if let thumbnail = attachment.thumbnail"))
        #expect(source.contains("Image(uiImage: thumbnail)"))
        #expect(!source.contains("UIImage(data: attachment.data)"))
    }

    @Test func conversationViewPreparesMediaDraftsAsynchronouslyBeforeAppending() throws {
        let source = try String(contentsOf: conversationViewSourceURL, encoding: .utf8)

        #expect(source.contains("try await MediaDraftProcessor.preparedAttachment(from: image, fileName: nil)"))
        #expect(source.contains("let attachment = try await MediaDraftProcessor.preparedAttachment(\n                        from: selection.data"))
        #expect(!source.contains("try appendMediaDraft(MediaDraftProcessor.attachment"))
    }

    private struct SampledColor {
        let red: CGFloat
        let blue: CGFloat
    }

    /// Averages a horizontal line of pixels at `sampleY` in a 100x400 image.
    private func averageColor(of image: UIImage, sampleY: Int) -> SampledColor? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        var raw = [UInt8](repeating: 0, count: width * 4)
        guard let context = CGContext(
            data: &raw,
            width: width,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        guard let row = cgImage.cropping(
            to: CGRect(x: 0, y: sampleY, width: width, height: 1)
        ) else { return nil }
        context.draw(row, in: CGRect(x: 0, y: 0, width: width, height: 1))

        var red = 0, blue = 0
        for x in 0..<width {
            red += Int(raw[x * 4])
            blue += Int(raw[x * 4 + 2])
        }
        return SampledColor(
            red: CGFloat(red) / CGFloat(width),
            blue: CGFloat(blue) / CGFloat(width)
        )
    }

    private var mediaComposerViewsSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("whitenoise-ios/Conversation/MediaComposerViews.swift")
    }

    private var conversationViewSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("whitenoise-ios/Conversation/ConversationView.swift")
    }
}

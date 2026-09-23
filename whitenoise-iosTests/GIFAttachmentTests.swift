import ImageIO
import MarmotKit
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import whitenoise_ios

@MainActor
struct GIFAttachmentTests {
    private let privateComment = "private-source-metadata"

    private func makeGIF() throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 2],
        ] as CFDictionary)
        let context = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (color, delay) in [(UIColor.red, 0.04), (UIColor.blue, 0.12)] {
            context.clear(CGRect(x: 0, y: 0, width: 4, height: 2))
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 1, y: 0, width: 3, height: 2))
            let frame = try #require(context.makeImage())
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay],
            ] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        var result = data as Data
        #expect(result.removeLast() == 0x3B)
        result.append(contentsOf: [0x21, 0xFE, UInt8(privateComment.utf8.count)])
        result.append(Data(privateComment.utf8))
        result.append(contentsOf: [0, 0x3B])
        return result
    }

    private func checkGIF(_ attachment: MediaDraftAttachment) throws {
        #expect(attachment.mediaType == "image/gif")
        #expect(attachment.fileName.lowercased().hasSuffix(".gif"))
        #expect(attachment.dim == "4x2")
        #expect(attachment.thumbnail != nil)
        #expect(attachment.thumbhash != nil)
        #expect(attachment.data.range(of: Data(privateComment.utf8)) == nil)
        #expect(attachment.uploadRequest.plaintext == attachment.data)
        #expect(attachment.uploadRequest.mediaType == "image/gif")
        #expect(attachment.messageDraftAttachment.plaintext == attachment.data)
        let source = try #require(CGImageSourceCreateWithData(attachment.data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.gif.identifier)
        #expect(CGImageSourceGetCount(source) == 2)
        let properties = try #require(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        let gif = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        #expect(gif[kCGImagePropertyGIFLoopCount] as? Int == 2)
        for (index, delay) in [0.04, 0.12].enumerated() {
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            let gif = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            let actualDelay = try #require(gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            #expect(abs(actualDelay - delay) < 0.001)
            let image = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
            let pixels = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            pixels.draw(image, in: CGRect(x: 0, y: 0, width: 4, height: 2))
            let bytes = try #require(pixels.data).assumingMemoryBound(to: UInt8.self)
            #expect(bytes[3] == 0, "GIF transparency survives preparation")
            #expect(bytes[4 + (index == 0 ? 0 : 2)] > 240, "Both distinct frames survive preparation")
        }
    }

    @Test(arguments: [UTType.gif.identifier, UTType.image.identifier, UTType.jpeg.identifier, nil])
    func preserveGIF(typeIdentifier: String?) async throws {
        let attachment = try await MediaDraftProcessor.preparedAttachment(
            from: makeGIF(), fileName: "animation.GIF", typeIdentifier: typeIdentifier)
        #expect(attachment.fileName == "animation.GIF")
        try checkGIF(attachment)
    }

    @Test func fileImportAndImageEntry() async throws {
        let data = try makeGIF()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).gif")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try checkGIF(await MediaDraftProcessor.preparedAttachment(fromFileURL: url))
        try checkGIF(MediaDraftProcessor.imageAttachment(from: data, fileName: nil))
        // Forwarding supplies no type hint and may have an incorrect filename.
        let forwarded = try await MediaDraftProcessor.preparedAttachment(from: data, fileName: "wrong.jpg")
        #expect(forwarded.fileName == "wrong.gif")
        try checkGIF(forwarded)
    }

    @Test(arguments: ["image/gif", "Image/GIF", " image/gif; charset=binary "])
    func recognizesGIF(mediaType: String) {
        let item = MessageMediaAttachment(id: "gif", reference: nil, fileName: "animation.gif",
            mediaType: mediaType, dim: nil, localData: nil)
        #expect(item.isGIF)
        let still = MessageMediaAttachment(id: "still", reference: nil, fileName: "photo.jpg",
            mediaType: "image/jpeg", dim: nil, localData: nil)
        #expect(!still.isGIF)
    }

    @Test func rejectsOversizedGIF() throws {
        var data = try makeGIF()
        data.append(Data(repeating: 0, count: MediaDraftProcessor.maxImageAttachmentBytes))
        #expect(throws: MediaDraftProcessor.Failure.self) {
            try MediaDraftProcessor.attachment(from: data, fileName: "large.gif")
        }
    }

    @Test func rejectsOversizedCanvas() throws {
        var data = try makeGIF()
        // GIF logical-screen dimensions are little-endian at offsets 6 and 8.
        data[6] = 0xFF
        data[7] = 0x7F
        #expect(throws: MediaDraftProcessor.Failure.self) {
            try AttachmentGIF.source(from: data)
        }
    }

    @Test func preserveDeltaFrames() throws {
        // Three optimized 2x2 subframes on a 4x2 canvas, at different offsets.
        let data = try #require(Data(base64Encoded:
            "R0lGODlhBAACAPEAAP8AAACAAAAA/wAAACH/C05FVFNDQVBFMi4wAwEBAAAh+QQEBAAAACwAAAAAAgACAAACAoRRACH5BAQEAAAALAIAAAACAAIAAAIClFUAIfkEBAQAAAAsAQAAAAIAAgAAAgKMUwA7"))
        let attachment = try MediaDraftProcessor.attachment(from: data, fileName: "delta.gif")
        #expect(attachment.dim == "4x2")
        let original = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let output = try #require(CGImageSourceCreateWithData(attachment.data as CFData, nil))
        #expect(CGImageSourceGetCount(output) == 3)
        for index in 0..<3 {
            let before = try #require(CGImageSourceCreateImageAtIndex(original, index, nil))
            let after = try #require(CGImageSourceCreateImageAtIndex(output, index, nil))
            #expect(try rgba(before) == rgba(after))
        }
        var excessive = data
        excessive[6] = 0
        excessive[7] = 16
        excessive[8] = 0
        excessive[9] = 16
        #expect(throws: MediaDraftProcessor.Failure.self) {
            try AttachmentGIF.source(from: excessive)
        }
        #expect(throws: MediaDraftProcessor.Failure.self) {
            try AttachmentGIF.source(from: Data(data.prefix(20)))
        }
    }

    private func rgba(_ image: CGImage) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 4, height: 2))
        return Data(bytes: try #require(context.data), count: 32)
    }

    @Test func staticPhotoStaysJPEG() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 2)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        }
        let data = try #require(image.pngData())
        let attachment = try MediaDraftProcessor.attachment(from: data, fileName: "photo.png")
        #expect(attachment.mediaType == "image/jpeg")
        #expect(attachment.fileName.hasSuffix(".jpg"))
        #expect(try AttachmentGIF.source(from: attachment.data) == nil)
    }
}

import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct MessageMediaThumbnailDecoderTests {

    @Test func decoderDownsamplesImageToPixelBudget() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 120))
        let data = renderer.jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 120))
        }

        let image = try #require(await MessageMediaThumbnailDecoder.image(
            data: data,
            maxPixelSize: 48,
            scale: 1
        ))
        let largestPixelEdge = max(image.size.width * image.scale, image.size.height * image.scale)

        #expect(largestPixelEdge <= 48)
    }

    @Test func videoDecoderExtractsAndCachesPreviewFrame() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageVideoThumbnail-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeTestVideo(to: url, size: CGSize(width: 96, height: 54))

        let image = try #require(await MessageVideoThumbnailDecoder.thumbnail(
            url: url,
            maxPixelSize: 48,
            scale: 1
        ))
        let largestPixelEdge = max(image.size.width * image.scale, image.size.height * image.scale)
        let itemID = "video-thumbnail-\(UUID().uuidString)"

        MessageVideoThumbnailDecoder.store(image, for: itemID, maxPixelSize: 48)
        let cached = try #require(MessageVideoThumbnailDecoder.cachedThumbnail(for: itemID, maxPixelSize: 48))

        #expect(largestPixelEdge <= 48)
        #expect(cached.size.width > 0)
    }

    private func writeTestVideo(to url: URL, size: CGSize) async throws {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw VideoThumbnailFixtureError.cannotAddInput
        }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.startWriting() else {
            throw writer.error ?? VideoThumbnailFixtureError.writerFailed
        }
        writer.startSession(atSourceTime: .zero)
        // `isReadyForMoreMediaData` is key-value observable: wait for it
        // instead of polling against a fixed budget.
        let ready = TestLatch()
        let readiness = input.observe(\.isReadyForMoreMediaData, options: [.initial, .new]) { @Sendable input, _ in
            if input.isReadyForMoreMediaData { ready.signal() }
        }
        defer { readiness.invalidate() }
        try await ready.wait()
        let firstBuffer = try makePixelBuffer(
            adaptor: adaptor,
            width: width,
            height: height
        )
        guard adaptor.append(firstBuffer, withPresentationTime: .zero) else {
            throw writer.error ?? VideoThumbnailFixtureError.writerFailed
        }
        let secondBuffer = try makePixelBuffer(
            adaptor: adaptor,
            width: width,
            height: height
        )
        guard adaptor.append(secondBuffer, withPresentationTime: CMTime(value: 1, timescale: 30)) else {
            throw writer.error ?? VideoThumbnailFixtureError.writerFailed
        }
        input.markAsFinished()
        nonisolated(unsafe) let completionWriter = writer
        try await withCheckedThrowingContinuation { continuation in
            writer.finishWriting {
                if completionWriter.status == AVAssetWriter.Status.completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: completionWriter.error ?? VideoThumbnailFixtureError.writerFailed)
                }
            }
        }
    }

    private func makePixelBuffer(
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else {
            throw VideoThumbnailFixtureError.missingPixelBufferPool
        }
        var maybeBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer)
        guard let buffer = maybeBuffer else {
            throw VideoThumbnailFixtureError.missingPixelBuffer
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw VideoThumbnailFixtureError.missingContext
        }
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        UIColor.systemIndigo.setFill()
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        return buffer
    }

    private enum VideoThumbnailFixtureError: Error {
        case cannotAddInput
        case missingContext
        case missingPixelBuffer
        case missingPixelBufferPool
        case writerFailed
    }
}

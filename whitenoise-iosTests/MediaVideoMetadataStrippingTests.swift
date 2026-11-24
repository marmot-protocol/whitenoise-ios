@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import whitenoise_ios

struct MediaVideoMetadataStrippingTests {
    private static let sampleGPS = "+37.33182-122.03118+010.000/"
    private static let sampleMake = "Apple"
    private static let sampleModel = "iPhone 16 Pro"
    private static let sampleSoftware = "18.4"
    private static let sampleCreationDate = "2026-05-01T12:34:56-0700"
    private static let sampleTrackNote = "Secret Track Location Note"

    @Test(arguments: [
        (fileType: AVFileType.mov, fileName: "clip.mov", typeID: UTType.quickTimeMovie.identifier),
        (fileType: AVFileType.mp4, fileName: "clip.mp4", typeID: UTType.mpeg4Movie.identifier),
    ])
    func stripsQuickTimeGPSAndDeviceMetadataFromDataAndFileURL(
        fileType: AVFileType,
        fileName: String,
        typeID: String
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoStripTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent(fileName)
        try await synthesizeTaggedVideo(
            at: sourceURL,
            fileType: fileType,
            width: 160,
            height: 120,
            transform: .identity
        )

        // Confirm the fixture actually carries GPS, device, and track metadata before stripping.
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceMetadata = try await allMetadataStrings(in: sourceAsset)
        #expect(sourceMetadata.contains { $0.contains("+37.33182") })
        #expect(sourceMetadata.contains { $0.contains(Self.sampleMake) })
        #expect(sourceMetadata.contains { $0.contains(Self.sampleModel) })
        #expect(sourceMetadata.contains { $0.contains(Self.sampleSoftware) })
        #expect(sourceMetadata.contains { $0.contains(Self.sampleCreationDate) })
        if fileType == .mov {
            #expect(sourceMetadata.contains { $0.contains(Self.sampleTrackNote) })
        }

        // Camera / file-importer path (`preparedAttachment(fromFileURL:)`).
        let fromURL = try await MediaDraftProcessor.preparedAttachment(fromFileURL: sourceURL)
        try await verifyStrippedAttachment(fromURL, expectedDim: "160x120", in: directory)

        // Photo-library path (`preparedAttachment(from:fileName:typeIdentifier:)`).
        let sourceData = try Data(contentsOf: sourceURL)
        let fromData = try await MediaDraftProcessor.preparedAttachment(
            from: sourceData,
            fileName: fileName,
            typeIdentifier: typeID
        )
        try await verifyStrippedAttachment(fromData, expectedDim: "160x120", in: directory)
    }

    @Test func preservesPortraitPreferredTransformWhileStrippingMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoStripRotateTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("portrait.mov")
        try await synthesizeTaggedVideo(
            at: sourceURL,
            fileType: .mov,
            width: 160,
            height: 120,
            transform: CGAffineTransform(rotationAngle: .pi / 2)
        )

        let attachment = try await MediaDraftProcessor.preparedAttachment(fromFileURL: sourceURL)
        try await verifyStrippedAttachment(attachment, expectedDim: "120x160", in: directory)
    }

    @Test func failsClosedWhenVideoBytesCannotBeStripped() async throws {
        let corrupt = Data("not a valid video container".utf8)

        await #expect(throws: MediaDraftProcessor.Failure.self) {
            _ = try await MediaDraftProcessor.preparedAttachment(
                from: corrupt,
                fileName: "broken.mov",
                typeIdentifier: UTType.quickTimeMovie.identifier
            )
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoStripFailClosed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let badURL = directory.appendingPathComponent("broken.mp4")
        try corrupt.write(to: badURL, options: .atomic)

        await #expect(throws: MediaDraftProcessor.Failure.self) {
            _ = try await MediaDraftProcessor.preparedAttachment(fromFileURL: badURL)
        }
    }

    @Test func removesWorkingTempFilesAfterStripping() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoStripCleanup-\(UUID().uuidString)", isDirectory: true)
        let workDirectory = directory.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("input.mov")
        try await synthesizeTaggedVideo(
            at: sourceURL,
            fileType: .mov,
            width: 160,
            height: 120,
            transform: .identity
        )

        let stripped = try await MediaVideoMetadataStripper.strip(
            sourceURL: sourceURL,
            preferredMediaType: "video/quicktime",
            directory: workDirectory
        )
        #expect(!stripped.data.isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: workDirectory.path)
        #expect(leftovers.isEmpty)
    }

    private func verifyStrippedAttachment(
        _ attachment: MediaDraftAttachment,
        expectedDim: String,
        in directory: URL
    ) async throws {
        #expect(attachment.kind == .video)
        #expect(!attachment.data.isEmpty)
        #expect(attachment.dim == expectedDim)
        #expect(attachment.thumbnail != nil)

        // Raw container bytes must not retain the sensitive strings.
        for secret in ["+37.33182", Self.sampleModel, Self.sampleCreationDate, Self.sampleTrackNote] {
            #expect(attachment.data.range(of: Data(secret.utf8)) == nil)
        }

        let ext = MediaAttachmentPolicy.fileExtension(for: attachment.mediaType)
        let strippedURL = directory.appendingPathComponent("stripped-\(UUID().uuidString).\(ext)")
        try attachment.data.write(to: strippedURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: strippedURL) }

        let asset = AVURLAsset(url: strippedURL)
        let metadataStrings = try await allMetadataStrings(in: asset)
        #expect(metadataStrings.isEmpty)

        let tracks = try await asset.load(.tracks)
        #expect(tracks.contains { $0.mediaType == .video })
        #expect(!tracks.contains { $0.mediaType == .metadata })
        for track in tracks {
            let trackMetadata = try await track.load(.metadata)
            #expect(trackMetadata.isEmpty)
        }
    }

    private func allMetadataStrings(in asset: AVURLAsset) async throws -> [String] {
        var values: [String] = []
        let topLevel = try await asset.load(.metadata)
        let common = try await asset.load(.commonMetadata)
        var allItems = topLevel + common
        for format in try await asset.load(.availableMetadataFormats) {
            allItems += try await asset.loadMetadata(for: format)
        }
        for track in try await asset.load(.tracks) {
            allItems += try await track.load(.metadata)
        }
        for item in allItems {
            if let string = try? await item.load(.stringValue), !string.isEmpty {
                values.append(string)
            }
        }
        return values
    }

    private func synthesizeTaggedVideo(
        at url: URL,
        fileType: AVFileType,
        width: Int,
        height: Int,
        transform: CGAffineTransform
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        if fileType == .mov {
            writer.metadata = [
                metadataItem(
                    keySpace: .quickTimeMetadata,
                    key: AVMetadataKey.quickTimeMetadataKeyLocationISO6709 as NSString,
                    value: Self.sampleGPS as NSString
                ),
                metadataItem(
                    keySpace: .quickTimeMetadata,
                    key: AVMetadataKey.quickTimeMetadataKeyMake as NSString,
                    value: Self.sampleMake as NSString
                ),
                metadataItem(
                    keySpace: .quickTimeMetadata,
                    key: AVMetadataKey.quickTimeMetadataKeyModel as NSString,
                    value: Self.sampleModel as NSString
                ),
                metadataItem(
                    keySpace: .quickTimeMetadata,
                    key: AVMetadataKey.quickTimeMetadataKeySoftware as NSString,
                    value: Self.sampleSoftware as NSString
                ),
                metadataItem(
                    keySpace: .quickTimeMetadata,
                    key: AVMetadataKey.quickTimeMetadataKeyCreationDate as NSString,
                    value: Self.sampleCreationDate as NSString
                ),
                metadataItem(
                    keySpace: .quickTimeUserData,
                    key: AVMetadataKey.quickTimeUserDataKeyLocationISO6709 as NSString,
                    value: Self.sampleGPS as NSString
                ),
            ]
        } else {
            writer.metadata = [
                metadataItem(identifier: .iTunesMetadataDescription, value: Self.sampleGPS as NSString),
                metadataItem(identifier: .iTunesMetadataUserComment, value: Self.sampleModel as NSString),
                metadataItem(identifier: .iTunesMetadataEncodingTool, value: Self.sampleSoftware as NSString),
                metadataItem(identifier: .iTunesMetadataReleaseDate, value: Self.sampleCreationDate as NSString),
                metadataItem(identifier: .iTunesMetadataArtist, value: Self.sampleMake as NSString),
            ]
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        input.metadata = [
            metadataItem(
                identifier: fileType == .mov ? .quickTimeMetadataDescription : .commonIdentifierDescription,
                value: Self.sampleTrackNote as NSString
            ),
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )

        #expect(writer.canAdd(input))
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frameIndex in 0..<5 {
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                nil,
                &pixelBuffer
            )
            #expect(status == kCVReturnSuccess)
            let buffer = try #require(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                memset(base, Int32((frameIndex * 40 + 60) % 255), bytesPerRow * height)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let pts = CMTime(value: CMTimeValue(frameIndex), timescale: 15)
            try await eventually {
                input.isReadyForMoreMediaData
            }
            #expect(adaptor.append(buffer, withPresentationTime: pts))
        }

        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed, "writer failed: \(String(describing: writer.error))")
    }

    private func metadataItem(
        keySpace: AVMetadataKeySpace,
        key: NSString,
        value: NSString
    ) -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = keySpace
        item.key = key
        item.value = value
        return item
    }

    private func metadataItem(
        identifier: AVMetadataIdentifier,
        value: NSString
    ) -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        return item
    }
}

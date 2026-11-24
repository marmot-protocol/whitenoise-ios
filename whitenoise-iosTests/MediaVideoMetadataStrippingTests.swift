@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import MarmotKit
import Synchronization
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

    @MainActor
    @Test func restoringPreUpgradeDraftStripsVideoMetadataAndReplacesStoredAttachment() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoDraftUpgradeTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("geotagged.mov")
        try await synthesizeTaggedVideo(
            at: sourceURL,
            fileType: .mov,
            width: 160,
            height: 120,
            transform: .identity
        )
        let originalData = try Data(contentsOf: sourceURL)
        let legacyID = UUID()
        let storedAttachment = MessageDraftAttachmentFfi(
            id: legacyID.uuidString,
            fileName: "geotagged.mov",
            mediaType: "video/quicktime",
            plaintext: originalData,
            dim: "160x120",
            thumbhash: nil,
            durationSeconds: nil,
            waveformSamples: []
        )
        let persistence = StubDraftPersistence(
            initialDraft: MessageDraftFfi(
                groupIdHex: "group-1",
                content: "Check this clip",
                replyToMessageIdHex: nil,
                mediaAttachments: [storedAttachment],
                createdAtMs: 1_000,
                updatedAtMs: 1_000
            )
        )
        let store = ConversationDraftStore(
            persistence: persistence,
            legacyFileURL: directory.appendingPathComponent("legacy.json")
        )

        let restored = try #require(await store.snapshot(accountRef: "alice", groupIdHex: "group-1"))
        let sanitized = try #require(restored.mediaAttachments.first)
        // Sanitized replacement gets a new ID so sending never uploads raw
        // pre-upgrade file-backed bytes, and restoring does NOT auto-rewrite
        // the durable draft before the composer saves.
        #expect(sanitized.id != legacyID)
        #expect(persistence.lastSavedSnapshot == nil)
        let inputs = MessageDraftAttachmentInputs.inputs(
            for: [sanitized],
            retainedIDs: [legacyID.uuidString],
            removingUnnamed: [legacyID.uuidString]
        )
        #expect(inputs.contains {
            if case .removed(let id) = $0 { return id == legacyID.uuidString }
            return false
        })
        #expect(inputs.contains {
            if case .inline(let attachment) = $0 { return attachment.id == sanitized.id.uuidString }
            return false
        })
        try await verifyStrippedAttachment(sanitized, expectedDim: "160x120", in: directory)

        // Once the composer saves the sanitized draft, reopening it is idempotent:
        // already-clean videos keep their exact ID and bytes with no re-remux.
        store.setDraft(restored, accountRef: "alice", groupIdHex: "group-1")
        await store.flush()
        let saved = try #require(persistence.lastSavedSnapshot)
        #expect(saved.mediaAttachments.map(\.id) == [sanitized.id])
        #expect(saved.mediaAttachments.first?.data.range(of: Data("+37.33182".utf8)) == nil)

        let reopenedStore = ConversationDraftStore(
            persistence: persistence,
            legacyFileURL: directory.appendingPathComponent("legacy-2.json")
        )
        let reopened = try #require(await reopenedStore.snapshot(accountRef: "alice", groupIdHex: "group-1"))
        let reopenedAttachment = try #require(reopened.mediaAttachments.first)
        #expect(reopenedAttachment.id == sanitized.id)
        #expect(reopenedAttachment.data == sanitized.data)

        // An unstrippable/corrupt video is omitted from the composer so raw bytes
        // cannot be sent, while leaving the durable draft intact in storage.
        let corruptID = UUID()
        let corruptPersistence = StubDraftPersistence(
            initialDraft: MessageDraftFfi(
                groupIdHex: "group-2",
                content: "Keep caption",
                replyToMessageIdHex: nil,
                mediaAttachments: [
                    MessageDraftAttachmentFfi(
                        id: corruptID.uuidString,
                        fileName: "broken.mov",
                        mediaType: "video/quicktime",
                        plaintext: Data("not a valid quicktime movie".utf8),
                        dim: nil,
                        thumbhash: nil,
                        durationSeconds: nil,
                        waveformSamples: []
                    ),
                ],
                createdAtMs: 1_000,
                updatedAtMs: 1_000
            )
        )
        let corruptStore = ConversationDraftStore(
            persistence: corruptPersistence,
            legacyFileURL: directory.appendingPathComponent("legacy-corrupt.json")
        )
        let corruptRestored = try #require(await corruptStore.snapshot(accountRef: "alice", groupIdHex: "group-2"))
        #expect(corruptRestored.canonicalText == "Keep caption")
        #expect(corruptRestored.mediaAttachments.isEmpty)
        #expect(corruptPersistence.lastSavedSnapshot == nil)
        #expect(corruptPersistence.storedDraft?.mediaAttachments.map(\.id) == [corruptID.uuidString])
    }

    @Test func allowsAudioOnlyMovieContainersWhileStrippingMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioOnlyMovieStripTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("voice-container.mov")
        try await synthesizeTaggedAudioOnlyMovie(at: sourceURL)

        let sourceMetadata = try await allMetadataStrings(in: AVURLAsset(url: sourceURL))
        #expect(sourceMetadata.contains { $0.contains("+37.33182") })

        let attachment = try await MediaDraftProcessor.preparedAttachment(fromFileURL: sourceURL)
        #expect(attachment.kind == .video)
        #expect(!attachment.data.isEmpty)
        #expect(attachment.data.range(of: Data("+37.33182".utf8)) == nil)

        let strippedURL = directory.appendingPathComponent("stripped-audio-only.mov")
        try attachment.data.write(to: strippedURL, options: .atomic)
        let strippedAsset = AVURLAsset(url: strippedURL)
        #expect(try await allMetadataStrings(in: strippedAsset).isEmpty)
        let tracks = try await strippedAsset.load(.tracks)
        #expect(tracks.contains { $0.mediaType == .audio })
    }

    @Test(.timeLimit(.minutes(1)))
    func multiTrackAppendFailureAndCancellationTerminateWithoutHanging() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiTrackFailureTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("av.mov")
        try await synthesizeTaggedVideoWithAudio(at: sourceURL, width: 160, height: 120)

        // Normal remux preserves both video and audio tracks and strips metadata.
        let stripped = try await MediaDraftProcessor.preparedAttachment(fromFileURL: sourceURL)
        try await verifyStrippedAttachment(stripped, expectedDim: "160x120", in: directory)
        let strippedURL = directory.appendingPathComponent("av-stripped.mov")
        try stripped.data.write(to: strippedURL, options: .atomic)
        let strippedTracks = try await AVURLAsset(url: strippedURL).load(.tracks)
        #expect(strippedTracks.contains { $0.mediaType == .video })
        #expect(strippedTracks.contains { $0.mediaType == .audio })

        // Force an append failure on track 0 while track 1 is still active:
        // copyRemainingSamples must cancel reader/writer and resume immediately.
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.load(.tracks).filter { $0.mediaType == .video || $0.mediaType == .audio }
        #expect(tracks.count == 2)
        let reader = try AVAssetReader(asset: asset)
        let outputURL = directory.appendingPathComponent("aborted.mov")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        var pairs: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []
        for track in tracks {
            let hint = try #require(try await track.load(.formatDescriptions).first)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            reader.add(output)
            writer.add(input)
            pairs.append((output, input))
        }
        #expect(reader.startReading())
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let outcome = await MediaVideoMetadataStripper.copyRemainingSamples(
            reader: reader,
            writer: writer,
            pairs: pairs
        ) { index, input, sample in
            if index == 0 { return false }
            return input.append(sample)
        }
        #expect(outcome == .failed)
        #expect(writer.status == .cancelled)

        // Task cancellation after copying begins must also cancel reader/writer
        // and return `.cancelled` without hanging.
        let cancelReader = try AVAssetReader(asset: asset)
        let cancelOutputURL = directory.appendingPathComponent("cancelled.mov")
        let cancelWriter = try AVAssetWriter(outputURL: cancelOutputURL, fileType: .mov)
        var cancelPairs: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []
        for track in tracks {
            let hint = try #require(try await track.load(.formatDescriptions).first)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            cancelReader.add(output)
            cancelWriter.add(input)
            cancelPairs.append((output, input))
        }
        #expect(cancelReader.startReading())
        #expect(cancelWriter.startWriting())
        cancelWriter.startSession(atSourceTime: .zero)

        let copyStarted = TestLatch()
        let cancelReady = DispatchSemaphore(value: 0)
        let cancelTask = Task {
            await MediaVideoMetadataStripper.copyRemainingSamples(
                reader: cancelReader,
                writer: cancelWriter,
                pairs: cancelPairs
            ) { index, input, sample in
                if index == 0 {
                    copyStarted.signal()
                    _ = cancelReady.wait(timeout: .now() + .seconds(5))
                }
                return input.append(sample)
            }
        }
        try await copyStarted.wait()
        cancelTask.cancel()
        cancelReady.signal()
        let cancelOutcome = await cancelTask.value
        #expect(cancelOutcome == .cancelled)
        #expect(cancelWriter.status == .cancelled)
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

    private func synthesizeTaggedAudioOnlyMovie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = [
            metadataItem(
                keySpace: .quickTimeMetadata,
                key: AVMetadataKey.quickTimeMetadataKeyLocationISO6709 as NSString,
                value: Self.sampleGPS as NSString
            ),
            metadataItem(
                keySpace: .quickTimeMetadata,
                key: AVMetadataKey.quickTimeMetadataKeyModel as NSString,
                value: Self.sampleModel as NSString
            ),
        ]
        let audioInput = makeAudioWriterInput()
        #expect(writer.canAdd(audioInput))
        writer.add(audioInput)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        try await appendSilentAudioSamples(to: audioInput, count: 6)
        audioInput.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed, "audio-only writer failed: \(String(describing: writer.error))")
    }

    private func synthesizeTaggedVideoWithAudio(at url: URL, width: Int, height: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = [
            metadataItem(
                keySpace: .quickTimeMetadata,
                key: AVMetadataKey.quickTimeMetadataKeyLocationISO6709 as NSString,
                value: Self.sampleGPS as NSString
            ),
            metadataItem(
                keySpace: .quickTimeMetadata,
                key: AVMetadataKey.quickTimeMetadataKeyModel as NSString,
                value: Self.sampleModel as NSString
            ),
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        let audioInput = makeAudioWriterInput()
        #expect(writer.canAdd(videoInput))
        #expect(writer.canAdd(audioInput))
        writer.add(videoInput)
        writer.add(audioInput)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frameIndex in 0..<6 {
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
            )
            #expect(status == kCVReturnSuccess)
            let buffer = try #require(pixelBuffer)
            let pts = CMTime(value: CMTimeValue(frameIndex), timescale: 15)
            try await eventually { videoInput.isReadyForMoreMediaData }
            #expect(adaptor.append(buffer, withPresentationTime: pts))
        }
        try await appendSilentAudioSamples(to: audioInput, count: 12)
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed, "av writer failed: \(String(describing: writer.error))")
    }

    private func makeAudioWriterInput() -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 64_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        return input
    }

    private func appendSilentAudioSamples(to input: AVAssetWriterInput, count: Int) async throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44_100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        #expect(fmtStatus == noErr)
        let format = try #require(formatDescription)
        let framesPerBuffer = 1024
        let byteCount = framesPerBuffer * 2

        for index in 0..<count {
            var blockBuffer: CMBlockBuffer?
            let blockStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            #expect(blockStatus == kCMBlockBufferNoErr)
            let block = try #require(blockBuffer)
            #expect(CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) == kCMBlockBufferNoErr)

            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 44_100),
                presentationTimeStamp: CMTime(value: CMTimeValue(index * framesPerBuffer), timescale: 44_100),
                decodeTimeStamp: .invalid
            )
            var sampleSize = byteCount
            var sampleBuffer: CMSampleBuffer?
            let sampleStatus = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: format,
                sampleCount: framesPerBuffer,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            )
            #expect(sampleStatus == noErr)
            let sample = try #require(sampleBuffer)
            try await eventually { input.isReadyForMoreMediaData }
            #expect(input.append(sample))
        }
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

@MainActor
private final class StubDraftPersistence: ConversationDraftPersistence {
    var storedDraft: MessageDraftFfi?
    var lastSavedSnapshot: ConversationDraftSnapshot?

    init(initialDraft: MessageDraftFfi?) {
        self.storedDraft = initialDraft
    }

    func loadMessageDraftSummaries(accountRef _: String) async throws -> [MessageDraftSummaryFfi] {
        guard let storedDraft else { return [] }
        return [
            MessageDraftSummaryFfi(
                groupIdHex: storedDraft.groupIdHex,
                content: storedDraft.content,
                replyToMessageIdHex: storedDraft.replyToMessageIdHex,
                mediaAttachments: storedDraft.mediaAttachments.map {
                    MessageDraftAttachmentSummaryFfi(
                        id: $0.id,
                        fileName: $0.fileName,
                        mediaType: $0.mediaType,
                        plaintextSize: UInt64($0.plaintext.count)
                    )
                },
                createdAtMs: storedDraft.createdAtMs,
                updatedAtMs: storedDraft.updatedAtMs
            ),
        ]
    }

    func loadMessageDraft(accountRef _: String, groupIdHex _: String) async throws -> MessageDraftFfi? {
        storedDraft
    }

    func persistMessageDraft(
        accountRef _: String,
        groupIdHex: String,
        snapshot: ConversationDraftSnapshot
    ) async throws -> MessageDraftFfi {
        lastSavedSnapshot = snapshot
        let saved = MessageDraftFfi(
            groupIdHex: groupIdHex,
            content: snapshot.canonicalText,
            replyToMessageIdHex: snapshot.replyToMessageIdHex,
            mediaAttachments: snapshot.mediaAttachments.map(\.messageDraftAttachment),
            createdAtMs: 1_000,
            updatedAtMs: 2_000
        )
        storedDraft = saved
        return saved
    }

    func deletePersistedMessageDraft(accountRef _: String, groupIdHex _: String) async throws {
        storedDraft = nil
    }
}

import AVFoundation
import Foundation
import Testing
@testable import whitenoise_ios

struct MessageAudioPlayerPreparerTests {
    @MainActor
    @Test func preparedPlayerWorkRunsOffMainThreadWhenCalledFromMainActor() async throws {
        let ranOnMainThread = try await MessageAudioPlayerPreparer.detachedPreparedValue(priority: .userInitiated) {
            Thread.isMainThread
        }

        #expect(ranOnMainThread == false)
    }

    @MainActor
    @Test func durationWorkRunsOffMainThreadWhenCalledFromMainActor() async {
        let ranOnMainThread = await MessageAudioPlayerPreparer.detachedValue(priority: .utility) {
            Thread.isMainThread
        }

        #expect(ranOnMainThread == false)
    }

    @MainActor
    @Test func fileBackedAudioPlayerOpensAndReportsDurationWithoutHeapData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioPreparerFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wavURL = directory.appendingPathComponent("clip.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_000))
        buffer.frameLength = 4_000
        do {
            let file = try AVAudioFile(forWriting: wavURL, settings: format.settings)
            try file.write(from: buffer)
        }

        let item = MessageMediaAttachment(
            id: "audio:0",
            reference: nil,
            fileName: "clip.wav",
            mediaType: "audio/wav",
            dim: nil,
            localData: nil
        )
        let hint = MessageAudioPlayerPreparer.fileTypeHint(for: item)
        let player = try await MessageAudioPlayerPreparer.preparedPlayer(from: wavURL, fileTypeHint: hint)
        let duration = await MessageAudioPlayerPreparer.duration(from: wavURL, fileTypeHint: hint)
        #expect(player.duration > 0.4 && player.duration < 0.6)
        #expect(duration != nil && abs((duration ?? 0) - player.duration) < 0.05)
    }
}

import Foundation
import Testing

struct MessageAudioPlayerPreparerTests {
    @Test func receivedAudioPlaybackBuildsAndPreparesPlayerOffMainActor() throws {
        let source = try sourceString("darkmatter-ios/Conversation/MessageBubble.swift")
        let preparer = try source.slice(
            from: "nonisolated enum MessageAudioPlayerPreparer {",
            to: "\n\nprivate struct MessageAudioAttachmentView"
        )
        let loadAndPlay = try source.slice(
            from: "    private func loadAndPlay() async {",
            to: "\n    private func loadMetadataIfNeeded() async {"
        )

        #expect(preparer.contains("Task.detached(priority: .userInitiated)"))
        #expect(preparer.contains("try AVAudioPlayer(data: data)"))
        #expect(preparer.contains("next.prepareToPlay()"))
        #expect(loadAndPlay.contains("try await MessageAudioPlayerPreparer.preparedPlayer(from: data)"))
        #expect(!loadAndPlay.contains("AVAudioPlayer(data: data)"))
        #expect(!loadAndPlay.contains("prepareToPlay()"))
    }

    @Test func receivedAudioMetadataDurationFallbackIsDetachedFromMainActor() throws {
        let source = try sourceString("darkmatter-ios/Conversation/MessageBubble.swift")
        let audioMetadata = try source.slice(
            from: "    private func audioMetadata(from data: Data) async -> MessageAudioMetadata {",
            to: "\n    private func applyMetadata(_ metadata: MessageAudioMetadata)"
        )

        #expect(audioMetadata.contains("await MessageAudioPlayerPreparer.duration(from: data)"))
        #expect(!audioMetadata.contains("AVAudioPlayer(data: data)"))
    }

    private func sourceString(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private enum SourceSliceError: Error {
    case missingStart(String)
    case missingEnd(String)
}

private extension String {
    func slice(from start: String, to end: String) throws -> String {
        guard let startRange = range(of: start) else {
            throw SourceSliceError.missingStart(start)
        }
        guard let endRange = self[startRange.upperBound...].range(of: end) else {
            throw SourceSliceError.missingEnd(end)
        }
        return String(self[startRange.lowerBound..<endRange.lowerBound])
    }
}

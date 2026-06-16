import Foundation
import Testing
@testable import darkmatter_ios

@MainActor
struct VoiceMessageRecorderLifecycleTests {
    @Test func meteringTaskDoesNotRetainRecorderOwner() async {
        var recorder: VoiceMessageRecorder? = VoiceMessageRecorder()
        weak var weakRecorder = recorder

        recorder?.startMeteringForTesting()
        recorder = nil
        await Task.yield()

        #expect(weakRecorder == nil)
    }

    @Test func pendingHoldTaskDoesNotRetainRecorderOwner() async {
        var recorder: VoiceMessageRecorder? = VoiceMessageRecorder()
        weak var weakRecorder = recorder

        recorder?.beginPress { _ in }
        #expect(recorder?.isActive == true)

        recorder = nil
        await Task.yield()

        #expect(weakRecorder == nil)
    }

    @Test func cancelIfActiveStopsPendingPressBeforeRecorderStarts() {
        let recorder = VoiceMessageRecorder()

        recorder.beginPress { _ in }
        #expect(recorder.isActive)

        recorder.cancelIfActive()

        #expect(!recorder.isActive)
    }

    @Test func conversationDisappearCancelsActiveVoiceRecording() throws {
        let source = try sourceString("darkmatter-ios/Conversation/ConversationView.swift")

        #expect(source.matches(#"\.onDisappear \{[\s\S]*voiceRecorder\.cancelIfActive\(\)[\s\S]*cancelPendingTimelineFollowUpWork\(\)"#))
    }

    private func sourceString(_ relativePath: String) throws -> String {
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

private extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}

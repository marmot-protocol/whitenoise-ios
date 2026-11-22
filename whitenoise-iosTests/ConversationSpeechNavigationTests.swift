import MarmotKit
import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
struct ConversationSpeechNavigationTests {
    @Test func readAloudIsOfferedOnlyForSpokenIncomingContent() {
        var record = AppMessageRecordFfi(messageIdHex: "row", direction: "received", groupIdHex: "group",
            sender: "peer", plaintext: "Meet at six", contentTokens: .emptyDocument, kind: MessageSemantics.kindChat,
            tags: [], recordedAt: 1, receivedAt: 1)
        func actions(emoji: Bool = false, spoken: Bool = true) -> [MessageSpeechAction] {
            MessageSpeechPresentation.textActions(for: record, myAccountID: nil, standaloneEmoji: emoji, hasSpokenText: spoken)
        }
        #expect(actions() == [.read])
        record.sticker = .init(packCoordinate: "pack", shortcode: "wave", plaintextSha256: "hash")
        #expect(actions() == [.read])
        record.sticker = nil
        #expect(actions(spoken: false).isEmpty)
        record.plaintext = ":marmot:"
        #expect(actions(emoji: true).isEmpty)
        record.plaintext = SharedLocationText.value(latitude: 45, longitude: 20)
        #expect(actions().isEmpty)
        record.plaintext = "https://media.giphy.com/media/abc/giphy.mp4\nvia GIPHY"
        #expect(actions().isEmpty)
        record.plaintext = "   "
        #expect(actions().isEmpty)
        record.direction = "sent"
        record.plaintext = "Meet at six"
        #expect(actions().isEmpty)
    }

    @Test func transcriptionNeedsOneReceivedRecordingAndRecognizesAnExistingTranscript() {
        var record = AppMessageRecordFfi(messageIdHex: "row", direction: "received", groupIdHex: "group",
            sender: "peer", plaintext: "", contentTokens: .emptyDocument, kind: MessageSemantics.kindChat,
            tags: [], recordedAt: 1, receivedAt: 1)
        let audio = MessageMediaAttachment(id: "audio", reference: nil, fileName: "voice.m4a", mediaType: "audio/mp4", dim: nil, localData: nil)
        #expect(MessageSpeechPresentation.voiceAttachment(for: record, myAccountID: nil, media: [audio])?.id == audio.id)
        #expect(MessageSpeechPresentation.voiceAttachment(for: record, myAccountID: nil, media: [audio, audio]) == nil)
        record.sender = String(repeating: "ab", count: 32)
        #expect(MessageSpeechPresentation.voiceAttachment(for: record, myAccountID: record.sender, media: [audio]) == nil)
        record.direction = "sent"
        #expect(MessageSpeechPresentation.voiceAttachment(for: record, myAccountID: nil, media: [audio]) == nil)
        #expect(MessageSpeechPresentation.voiceActions(isTranscribing: false, transcriptVisible: nil, offersTranscribe: false).isEmpty)
        #expect(MessageSpeechPresentation.voiceActions(isTranscribing: false, transcriptVisible: nil, offersTranscribe: true) == [.transcribe])
        #expect(MessageSpeechPresentation.voiceActions(isTranscribing: false, transcriptVisible: true, offersTranscribe: false) == [.hide, .copy])
    }

    @Test func aRetainedRecordingAtTheSizeLimitCanBeReadAndALargerOneGetsASizeError() throws {
        let limit = UInt64(MessageMediaAttachment.audioAnalysisByteLimit)
        try LocalVoiceAttachment.validateSize(limit)
        #expect(throws: LocalVoiceAttachment.SizeError.tooLarge) { try LocalVoiceAttachment.validateSize(limit + 1) }
        #expect(throws: LocalVoiceAttachment.SizeError.empty) { try LocalVoiceAttachment.validateSize(0) }
    }

    @Test func readingMarkupWithNoSpokenTextExplainsWhyPlaybackDidNotStart() async throws {
        let speech = ConversationSpeech()
        let empty = TestLatch()
        speech.read(markdown: String(repeating: "[](https://example.com)", count: 400), id: "message") {
            empty.signal()
        }
        try await empty.wait()
        #expect(speech.readingID == nil)
    }

    @Test func uncertainRetentionHidesTextAndOnlyConfirmedAbsenceDiscardsIt() throws {
        let route = ConversationSpeech.Route(groupID: "chat", modelID: nil, account: "me", runtimeGeneration: 1)
        let original = ConversationSpeech.Scope(route: route, revision: 4)
        let revised = ConversationSpeech.Scope(route: route, revision: 5)
        let recording = ConversationSpeech.Recording(displayID: "audio", target: .init(
            messageIdHex: "message", sourceMessageIdHex: "original", attachmentIndex: 0))
        let transcript = ConversationSpeech.Transcript(scope: original, recording: recording, text: "Meet at six")
        let uncertain = try #require(transcript.revalidated(held: nil, in: revised))
        #expect(!uncertain.isVerified(in: revised))
        let restored = try #require(uncertain.revalidated(held: true, in: revised))
        #expect(restored.isVerified(in: revised))
        #expect(restored.text == transcript.text)
        #expect(restored.revalidated(held: false, in: revised) == nil)
    }

    @Test func voiceSourceHintAcceptsOnlyItsResolvedTargetWhenTheDirectTargetArrives() {
        let recording = ConversationSpeech.Recording(displayID: "audio", target: .init(
            messageIdHex: "message", sourceMessageIdHex: "original", attachmentIndex: 0))
        var media = MessageMediaAttachment(id: "audio", reference: nil, fileName: "voice.m4a", mediaType: "audio/mp4", dim: nil, localData: nil)
        media.sourceHint = .init(messageID: "message", slot: 0)
        #expect(recording.matches(media))
        media.localTarget = recording.target
        #expect(recording.matches(media))
        media.localTarget?.sourceMessageIdHex = "replacement"
        #expect(!recording.matches(media))
    }

    @available(iOS 26, *)
    @Test func poppingPastAnOpenDetailClearsTheChatsSpeechSession() async throws {
        let model = SpeechStackHarness.Model()
        let host = UIHostingController(rootView: SpeechStackHarness(model: model))
        try await withHostedWindow(host) { window in
            model.path = [.init(groupIdHex: "chat")]
            try await settleLayout(window) { model.visible }
            #expect(model.visible == "chat")
            // Keep a real transcription request pending at its data read while navigating.
            let started = TestLatch()
            let cancelled = TestLatch()
            let recording = ConversationSpeech.Recording(displayID: "audio", target: .init(
                messageIdHex: "voice-note", sourceMessageIdHex: "source", attachmentIndex: 0))
            let route = ConversationSpeech.Route(groupID: "chat", modelID: nil, account: nil, runtimeGeneration: 0)
            model.speech.transcribe(id: "voice-note", recording: recording, scope: .init(route: route, revision: 0), data: {
                started.signal()
                defer { if Task.isCancelled { cancelled.signal() } }
                try await parkUntilCancelled()
                return Data()
            }, revalidate: { _ in nil }, onError: { Issue.record("Cancelled transcription reported an error") })
            try await started.wait()
            model.showsDetails = true
            try await settleLayout(window) { model.visible }
            #expect(model.visible == "details")
            #expect(model.speech.transcribingID == "voice-note")
            model.path = []
            try await settleLayout(window) { model.speech.transcribingID == nil }
            try await cancelled.wait()
            #expect(model.speech.transcribingID == nil)
        }
    }
}

private struct SpeechStackHarness: View {
    @Observable @MainActor final class Model {
        var path: [ChatsListView.ChatNavigationTarget] = []
        var showsDetails = false
        var visible = ""
        let speech = ConversationSpeech()
    }
    @Bindable var model: Model

    var body: some View {
        NavigationStack(path: $model.path) {
            Text("Chats")
                .navigationDestination(for: ChatsListView.ChatNavigationTarget.self) { target in
                    Text(target.groupIdHex)
                        .onAppear { model.visible = target.groupIdHex }
                        .navigationDestination(isPresented: $model.showsDetails) {
                            Text("Details").onAppear { model.visible = "details" }
                        }
                }
        }
        .transaction { $0.disablesAnimations = true }
        .modifier(ConversationSpeechSession(speech: model.speech, route: ChatsListView.SpeechRoute(chat: model.path.last,
            settings: false, account: nil, generation: 0)))
    }
}

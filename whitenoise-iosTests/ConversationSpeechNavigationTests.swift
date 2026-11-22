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
        record.plaintext = "\u{202E}\u{FEFF}\t"
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
        func actions(visible: Bool? = nil, supported: Bool = true) -> [MessageSpeechAction] {
            MessageSpeechPresentation.voiceActions(for: record, isTranscribing: false, transcriptVisible: visible, supportsTranscription: supported)
        }
        #expect(MessageSpeechPresentation.receivedAudio(for: record, myAccountID: nil, media: [audio])?.id == audio.id)
        #expect(MessageSpeechPresentation.receivedAudio(for: record, myAccountID: nil, media: [audio, audio]) == nil)
        #expect(actions(supported: false).isEmpty)
        #expect(actions() == [.transcribe])
        record.plaintext = "The gate number changed"
        #expect(MessageSpeechPresentation.receivedAudio(for: record, myAccountID: nil, media: [audio])?.id == audio.id)
        #expect(actions().isEmpty)
        #expect(actions(visible: true) == [.hide, .copy])
        #expect(actions(visible: false) == [.show])
        record.sender = String(repeating: "ab", count: 32)
        #expect(MessageSpeechPresentation.receivedAudio(for: record, myAccountID: record.sender, media: [audio]) == nil)
        record.direction = "sent"
        #expect(MessageSpeechPresentation.receivedAudio(for: record, myAccountID: nil, media: [audio]) == nil)
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
        let markup = String(repeating: "[](https://example.com)", count: 400)
        speech.read(markdown: markup, id: "message", sourceText: markup) {
            empty.signal()
        }
        try await empty.wait()
        #expect(speech.readingID == nil)
    }

    @Test func editingTheActiveMessageStopsReadingItsOldWords() {
        let speech = ConversationSpeech()
        let text = "Meet at the old address"
        speech.read(markdown: text, id: "message", sourceText: text) { Issue.record("The message contained text") }
        speech.prune(currentText: { _ in text }, audioMatches: { _, _ in false })
        #expect(speech.readingID == "message")
        speech.prune(currentText: { _ in "Meet at the new address" }, audioMatches: { _, _ in false })
        #expect(speech.readingID == nil)
    }

    @Test func aNewTranscriptGetsCheckedEvenIfItsOpeningRevisionAlreadyChanged() async throws {
        let speech = ConversationSpeech()
        let route = ConversationSpeech.Route(groupID: "chat", modelID: nil, account: "me", runtimeGeneration: 1)
        let opening = ConversationSpeech.Scope(route: route, revision: 1)
        let current = ConversationSpeech.Scope(route: route, revision: 2)
        let recording = ConversationSpeech.Recording(displayID: "audio", target: .init(
            messageIdHex: "message", sourceMessageIdHex: "source", attachmentIndex: 0))
        let previousCheck = speech.retentionCheck(in: current)
        await speech.revalidate(in: current) { _, _ in false }
        speech.stageTranscript("Gate 12", id: "message", recording: recording, scope: opening)
        #expect(speech.retentionCheck(in: current) != previousCheck)
        #expect(speech.transcribingID == "message")
        #expect(speech.transcripts["message"]?.isVerified(in: current) == false)
        await speech.revalidate(in: current) { id, source in id == "message" && source == recording }
        #expect(speech.transcripts["message"]?.isVerified(in: current) == true)
        #expect(speech.transcribingID == nil)
    }

    @Test func anOlderLookupCannotHideWordsThatTheMenuJustVerified() async {
        let speech = ConversationSpeech()
        let scope = ConversationSpeech.Scope(route: .init(groupID: "chat", modelID: nil, account: "me", runtimeGeneration: 1), revision: 4)
        let recording = ConversationSpeech.Recording(displayID: "audio", target: .init(
            messageIdHex: "message", sourceMessageIdHex: "original", attachmentIndex: 0))
        speech.stageTranscript("Meet at six", id: "message", recording: recording, scope: scope)
        await speech.revalidate(in: scope) { id, recording in
            speech.updateRetention(true, id: id, recording: recording, scope: scope)
            return nil
        }
        #expect(speech.transcripts["message"]?.display(in: scope) == .text("Meet at six"))
        #expect(speech.transcribingID == nil)
    }

    @Test(arguments: [true, false])
    func aDefinitiveLookupStillAppliesAfterAnInconclusiveMenuCheck(held: Bool) async {
        let speech = ConversationSpeech()
        let route = ConversationSpeech.Route(groupID: "chat", modelID: nil, account: "me", runtimeGeneration: 1)
        let original = ConversationSpeech.Scope(route: route, revision: 1)
        let revised = ConversationSpeech.Scope(route: route, revision: 2)
        let recording = ConversationSpeech.Recording(displayID: "audio", target: .init(
            messageIdHex: "message", sourceMessageIdHex: "original", attachmentIndex: 0))
        speech.stageTranscript("Gate 12", id: "message", recording: recording, scope: original)
        speech.updateRetention(true, id: "message", recording: recording, scope: original)
        await speech.revalidate(in: revised) { id, recording in
            speech.updateRetention(nil, id: id, recording: recording, scope: revised)
            #expect(speech.transcripts[id]?.display(in: revised) == .checkFailed)
            return held
        }
        if held {
            #expect(speech.transcripts["message"]?.display(in: revised) == .text("Gate 12"))
        } else {
            #expect(speech.transcripts["message"] == nil)
        }
    }

    @Test func uncertainRetentionHidesTextAndOnlyConfirmedAbsenceDiscardsIt() throws {
        let route = ConversationSpeech.Route(groupID: "chat", modelID: nil, account: "me", runtimeGeneration: 1)
        let original = ConversationSpeech.Scope(route: route, revision: 4)
        let revised = ConversationSpeech.Scope(route: route, revision: 5)
        let recording = ConversationSpeech.Recording(displayID: "audio", target: .init(
            messageIdHex: "message", sourceMessageIdHex: "original", attachmentIndex: 0))
        let transcript = ConversationSpeech.Transcript(scope: original, recording: recording, text: "Meet at six")
        let uncertain = try #require(transcript.revalidated(held: nil, in: revised))
        #expect(transcript.display(in: revised) == nil)
        #expect(uncertain.display(in: revised) == .checkFailed)
        let restored = try #require(uncertain.revalidated(held: true, in: revised))
        #expect(restored.isVerified(in: revised))
        #expect(restored.display(in: revised) == .text("Meet at six"))
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
    @Test(arguments: [false, true])
    func leavingTheChatClearsSpeechEvenWhenADetailCoversIt(removingStack: Bool) async throws {
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
            }, isCurrent: { true }, onError: { Issue.record("Cancelled transcription reported an error") })
            try await started.wait()
            model.showsMedia = true
            try await model.coverOpened.wait()
            #expect(model.speech.transcribingID == "voice-note")
            model.showsMedia = false
            try await model.coverDismissed.wait()
            #expect(model.speech.transcribingID == "voice-note")
            model.showsDetails = true
            try await settleLayout(window) { model.visible }
            #expect(model.visible == "details")
            #expect(model.speech.transcribingID == "voice-note")
            if removingStack {
                model.showsStack = false
            } else {
                model.path = []
            }
            try await settleLayout(window) { model.speech.transcribingID == nil }
            try await cancelled.wait()
            #expect(model.speech.transcribingID == nil)
        }
    }
}

private struct SpeechStackHarness: View {
    @Observable @MainActor final class Model {
        var path: [ChatsListView.ChatNavigationTarget] = []
        var showsStack = true
        var showsDetails = false
        var showsMedia = false
        let coverOpened = TestLatch()
        let coverDismissed = TestLatch()
        var visible = ""
        let speech = ConversationSpeech()
    }
    @Bindable var model: Model

    var body: some View {
        if model.showsStack { stack }
    }

    private var stack: some View {
        NavigationStack(path: $model.path) {
            Text("Chats")
                .navigationDestination(for: ChatsListView.ChatNavigationTarget.self) { target in
                    Text(target.groupIdHex)
                        .fullScreenCover(isPresented: $model.showsMedia, onDismiss: { model.coverDismissed.signal() }) {
                            Text("Media").onAppear { model.coverOpened.signal() }
                        }
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

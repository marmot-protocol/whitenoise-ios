import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
struct ConversationSpeechNavigationTests {
    @Test func readingMarkupWithNoSpokenTextExplainsWhyPlaybackDidNotStart() async throws {
        let speech = ConversationSpeech()
        let empty = TestLatch()
        speech.read(markdown: String(repeating: "[](https://example.com)", count: 400), id: "message") {
            empty.signal()
        }
        try await empty.wait()
        #expect(speech.readingID == nil)
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
            model.speech.transcribe(id: "voice-note", attachmentID: "audio", data: {
                started.signal()
                defer { if Task.isCancelled { cancelled.signal() } }
                try await parkUntilCancelled()
                return Data()
            }, verifiedScope: { nil }, onError: { Issue.record("Cancelled transcription reported an error") })
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

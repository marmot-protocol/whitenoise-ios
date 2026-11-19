import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
struct ConversationSpeechNavigationTests {
    @Test func poppingPastAnOpenDetailClearsTheChatsSpeechSession() async throws {
        let model = SpeechStackHarness.Model()
        let host = UIHostingController(rootView: SpeechStackHarness(model: model))
        try await withHostedWindow(host) { window in
            model.path = [.init(groupIdHex: "chat")]
            try await settleLayout(window) { model.visible }
            #expect(model.visible == "chat")
            let route = ConversationSpeech.Route(groupID: "chat", modelID: nil, account: nil, runtimeGeneration: 0)
            model.speech.availableAudio = ("voice-note", .bundled(URL(fileURLWithPath: "/test/voice.m4a")),
                                           .init(route: route, revision: 0))
            model.showsDetails = true
            try await settleLayout(window) { model.visible }
            #expect(model.visible == "details")
            #expect(model.speech.availableAudio?.id == "voice-note")
            model.path = []
            try await settleLayout(window) { model.speech.availableAudio == nil }
            #expect(model.speech.availableAudio == nil)
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

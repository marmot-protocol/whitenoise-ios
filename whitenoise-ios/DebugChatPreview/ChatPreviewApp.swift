#if DEBUG
import MarmotKit
import SwiftUI

@main
enum DebugAppLauncher {
    static func main() {
        if CommandLine.arguments.contains("-ChatPreview"), !ProcessEnvironment.isUnitTestHost() {
            ChatPreviewApp.main()
        } else {
            whitenoise_iosApp.main()
        }
    }
}

private struct ChatPreviewApp: App {
    @State private var session = ChatPreviewSession()

    var body: some Scene {
        WindowGroup {
            ChatPreviewInbox(session: session)
                .toastHost()
                .environment(\.isChatFixture, true)
                .environment(\.emojiRecentsDefaults, session.defaults)
                .environment(session.state)
                .environment(session.state.toastState)
                .environment(session.state.navigation)
                .environment(session.appearance)
                .appAppearance(session.appearance)
        }
    }
}

private struct ChatPreviewInbox: View {
    let session: ChatPreviewSession
    @State private var path: [String] = []
    @State private var speech = ConversationSpeech()

    var body: some View {
        NavigationStack(path: $path) {
            List(session.inbox.items) { item in
                NavigationLink(value: item.id) { ChatRow(item: item) }
            }
            .listStyle(.plain)
            .navigationTitle("Chats")
            .navigationDestination(for: String.self) { id in
                if let item = session.inbox.item(groupIdHex: id) {
                    ChatPreviewDestination(session: session, item: item)
                }
            }
        }
        .modifier(ConversationSpeechSession(speech: speech, route: path.last))
    }
}

@MainActor
final class ChatPreviewSession {
    let defaults: UserDefaults
    let state: AppState
    let appearance: AppAppearanceStore
    let inbox: ChatsListViewModel
    let windows: ChatPreviewWindows

    init() {
        // A dedicated suite ensures fixture identities never replace a real selection.
        let suite = "dev.ipf.whitenoise.chat-preview"
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Preview preferences unavailable") }
        self.defaults = defaults
        defaults.removePersistentDomain(forName: suite)
        let state = AppState(client: nil, notifications: AppNotifications(),
            accountDefaults: defaults, erasureDefaults: defaults, preferenceDefaults: defaults,
            runtimeClientFactory: { _, _, _, _ in throw CancellationError() })
        state.isAppSceneActive = false
        state.accountStore.accounts = [AccountSummaryFfi(label: "preview", accountIdHex: ChatPreviewThread.owner,
            localSigning: false, signedOut: false, running: false)]
        state.activeAccountRef = "preview"
        self.state = state
        appearance = AppAppearanceStore(defaults: defaults)
        let windows = ChatPreviewWindows(chats: ChatPreviewThread.examples)
        self.windows = windows
        let inbox = ChatsListViewModel(appState: state)
        self.inbox = inbox
        var revision: UInt64 = 0
        windows.onChange = { chats in
            revision += 1
            inbox.applyPresentedSnapshot(.init(rows: chats.map(\.row),
                presentationVersion: .init(accountStoreEpoch: Data([1]), revision: revision)))
        }
        windows.onChange?(windows.chats)
    }
}

private struct ChatPreviewDestination: View {
    let session: ChatPreviewSession
    let item: ChatsListViewModel.Item
    @State private var model: ConversationViewModel?

    private var actions: ChatPreviewActions {
        ChatPreviewActions(windows: session.windows, id: item.id)
    }

    var body: some View {
        Group {
            if let model {
                ConversationView(previewItem: item, model: model, actions: actions)
            } else {
                ProgressView()
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
        .onAppear {
            guard model == nil else { return }
            let windows = session.windows
            var group = item.projectedGroup
            if let thread = windows.chats.first(where: { $0.id == item.id }) {
                group.disappearingMessageSecs = thread.disappearingMessageSecs
            }
            let model = ConversationViewModel(appState: session.state, group: group,
                initialTitle: item.title, initialOtherMember: item.directPeerAccountIdHex)
            model.fixtureActions = actions
            model.stickerAssets = ChatPreviewStickers.store()
            self.model = model
        }
    }
}
#endif

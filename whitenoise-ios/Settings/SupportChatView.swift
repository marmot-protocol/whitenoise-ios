import SwiftUI

struct SupportChatView: View {
    let chatsViewModel: ChatsListViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var chatTarget: ChatsListView.ChatNavigationTarget?

    @Environment(AppState.self) private var appState
    @State private var model = SupportChatViewModel()
    @State private var requestID: UUID?

    init(chatsViewModel: ChatsListViewModel, initialTarget: ChatsListView.ChatNavigationTarget?) {
        self.chatsViewModel = chatsViewModel
        _chatTarget = State(initialValue: initialTarget)
    }

    var body: some View {
        Group {
            if let chatTarget {
                ChatDestination(
                    target: chatTarget,
                    viewModel: chatsViewModel,
                    appState: appState,
                    onGroupLeft: { groupIdHex in
                        chatsViewModel.markGroupLeft(groupIdHex: groupIdHex)
                        dismiss()
                    },
                    onGroupDeleted: { groupIdHex in
                        chatsViewModel.removeChatListRow(groupIdHex: groupIdHex)
                        dismiss()
                    }
                )
            } else {
                introduction
            }
        }
        .task(id: requestID) {
            guard requestID != nil else { return }
            let accountRef = appState.activeAccountRef
            let generation = appState.runtimeGeneration
            var destinationGroupId: String?
            await model.start(using: appState) { destinationGroupId = $0 }
            defer {
                if chatTarget == nil { model.resetRouting() }
            }
            guard let groupIdHex = destinationGroupId, !Task.isCancelled,
                  appState.activeAccountRef == accountRef,
                  appState.runtimeGeneration == generation else { return }
            // Keep Start Chat's progress visible until the destination has its row.
            if chatsViewModel.item(groupIdHex: groupIdHex) == nil {
                await chatsViewModel.refreshRow(groupIdHex: groupIdHex)
            }
            guard !Task.isCancelled, appState.activeAccountRef == accountRef,
                  appState.runtimeGeneration == generation, appState.pendingChatId == nil else { return }
            openChat(groupIdHex: groupIdHex)
        }
    }

    private func openChat(groupIdHex: String) {
        chatsViewModel.retainDestination(groupIdHex: groupIdHex)
        // Replace the introduction in this navigation entry so Back goes to Settings.
        chatTarget = ChatsListView.ChatNavigationTarget(
            groupIdHex: groupIdHex,
            performance: appState.beginConversationOpenPerformance()
        )
    }

    private var introduction: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    WhiteNoiseSupportAvatar(size: 56)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("White Noise Support")
                            .font(.headline)
                        Text("Questions, problems, and suggestions")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            } footer: {
                Text("Ask how something works, report a problem, or share a suggestion.")
            }

            Section {
                WNButton(
                    title: "Start Chat",
                    systemImage: "plus.bubble",
                    isLoading: model.phase == .loading || model.phase == .routing
                ) {
                    requestID = UUID()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .localizedNavigationTitle("Chat with support")
        .navigationBarTitleDisplayMode(.inline)
        .alert(SupportChatPresentation.failureTitle, isPresented: failureBinding) {
            Button("Try Again") { requestID = UUID() }
            Button("Cancel", role: .cancel) { model.dismissFailure() }
        } message: {
            Text(SupportChatPresentation.failureMessage)
        }
        .interactiveDismissDisabled(model.isCreatingChat)
    }

    private var failureBinding: Binding<Bool> {
        Binding(
            get: { model.phase == .failed },
            set: { if !$0 { model.dismissFailure() } }
        )
    }
}

struct WhiteNoiseSupportAvatar: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "questionmark.bubble")
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background(Color(uiColor: .secondarySystemFill), in: Circle())
            .accessibilityHidden(true)
    }
}

nonisolated enum WhiteNoiseSupportContact {
    static let npub = "npub1zymqqmvktw8lkr5dp6zzw5xk3fkdqcynj4l3f080k3amy28ses6setzznv"

    static var recipient: ResolvedRecipient? {
        RecipientIdentifierQuery.resolvedProfileReference(npub)
    }
}

nonisolated enum SupportChatPresentation {
    static var failureTitle: String {
        L10n.string("Couldn't connect to support")
    }

    static var failureMessage: String {
        L10n.string("Please check your connection and try again.")
    }
}

@MainActor
@Observable
final class SupportChatViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case routing
        case failed
    }

    private(set) var phase: Phase = .idle
    let chatFlow: NewChatFlowViewModel

    init() {
        chatFlow = NewChatFlowViewModel()
        chatFlow.starter.playsSuccessHaptic = false
    }

    init(chatFlow: NewChatFlowViewModel) {
        self.chatFlow = chatFlow
        chatFlow.starter.playsSuccessHaptic = false
    }

    var isCreatingChat: Bool {
        chatFlow.starter.isCreating
    }

    func start(using appState: AppState, onOpen: @escaping (String) -> Void) async {
        guard phase == .idle || phase == .failed,
              let recipient = WhiteNoiseSupportContact.recipient
        else {
            if WhiteNoiseSupportContact.recipient == nil {
                phase = .failed
            }
            return
        }

        phase = .loading
        chatFlow.startPrompt = nil
        await chatFlow.startChat(
            accountIdHex: recipient.accountIdHex,
            memberRef: recipient.memberRef,
            using: appState,
            onOpen: { [weak self] groupIdHex in
                guard !Task.isCancelled else { return }
                self?.phase = .routing
                onOpen(groupIdHex)
            }
        )
        if phase != .routing {
            phase = chatFlow.startPrompt == nil ? .idle : .failed
        }
    }

    func retry(using appState: AppState, onOpen: @escaping (String) -> Void) async {
        guard phase == .failed, chatFlow.startPrompt != nil else {
            await start(using: appState, onOpen: onOpen)
            return
        }

        phase = .loading
        await chatFlow.retryStart(
            using: appState,
            onOpen: { [weak self] groupIdHex in
                guard !Task.isCancelled else { return }
                self?.phase = .routing
                onOpen(groupIdHex)
            }
        )
        if phase != .routing {
            phase = chatFlow.startPrompt == nil ? .idle : .failed
        }
    }

    /// A stale or cancelled destination must leave Start Chat available for another attempt.
    func resetRouting() {
        guard phase == .routing else { return }
        phase = .idle
    }

    func dismissFailure() {
        guard phase == .failed else { return }
        phase = .idle
        chatFlow.startPrompt = nil
    }
}

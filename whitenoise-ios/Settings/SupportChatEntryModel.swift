import Foundation

/// Resolves the Settings destination without creating a conversation.
@MainActor
@Observable
final class SupportChatEntryModel {
    struct Destination: Hashable, Identifiable {
        let id = UUID()
        let chatTarget: ChatsListView.ChatNavigationTarget?
    }

    private(set) var isLoading = false
    var showsFailure = false
    var destination: Destination?
    private let chatFlow: NewChatFlowViewModel

    init() {
        chatFlow = NewChatFlowViewModel()
    }

    init(chatFlow: NewChatFlowViewModel) {
        self.chatFlow = chatFlow
    }

    func prepare(
        using appState: AppState,
        prepareDestination: (String) async -> Void = { _ in }
    ) async {
        guard !isLoading, destination == nil else { return }
        guard let recipient = WhiteNoiseSupportContact.recipient else {
            showsFailure = true
            return
        }
        let accountRef = appState.activeAccountRef
        let generation = appState.runtimeGeneration
        isLoading = true
        showsFailure = false
        defer { isLoading = false }

        do {
            let groupIdHex = try await chatFlow.existingDirectChatGroupIdHex(
                accountIdHex: recipient.accountIdHex,
                using: appState
            )
            guard !Task.isCancelled, appState.activeAccountRef == accountRef,
                  appState.runtimeGeneration == generation, appState.pendingChatId == nil else { return }
            if let groupIdHex {
                await prepareDestination(groupIdHex)
            }
            guard !Task.isCancelled, appState.activeAccountRef == accountRef,
                  appState.runtimeGeneration == generation, appState.pendingChatId == nil else { return }
            destination = Destination(chatTarget: groupIdHex.map {
                ChatsListView.ChatNavigationTarget(
                    groupIdHex: $0,
                    performance: appState.beginConversationOpenPerformance()
                )
            })
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, appState.activeAccountRef == accountRef,
                  appState.runtimeGeneration == generation, appState.pendingChatId == nil else { return }
            showsFailure = true
            Haptics.error()
        }
    }
}

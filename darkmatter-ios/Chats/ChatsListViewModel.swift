import Foundation
import Observation
import MarmotKit

/// Owns the live list of chats for the currently active account. Wires the
/// initial snapshot from `subscribeChats(..)` into the view, then folds in
/// every subsequent update.
@Observable
final class ChatsListViewModel {

    private(set) var chats: [AppGroupRecordFfi] = []
    private(set) var isLoading: Bool = false
    private(set) var loadError: String?

    private weak var appState: AppState?
    private var subscriptionTask: Task<Void, Never>?
    private var currentAccount: String?

    init(appState: AppState) {
        self.appState = appState
    }

    deinit {
        subscriptionTask?.cancel()
    }

    /// Begin (or rebind, when `accountRef` changes) the chats subscription.
    func bind(accountRef: String?) async {
        if currentAccount == accountRef { return }
        subscriptionTask?.cancel()
        subscriptionTask = nil
        chats = []
        loadError = nil
        currentAccount = accountRef

        guard let accountRef, let appState else { return }
        isLoading = true
        do {
            let sub = try appState.marmot.subscribeChats(
                accountRef: accountRef,
                includeArchived: false
            )
            chats = sub.snapshot().sorted(by: ChatsListViewModel.sortRule)
            isLoading = false
            subscriptionTask = Task { [weak self] in
                for await update in SubscriptionDriver.chats(sub) {
                    await self?.fold(update)
                }
            }
        } catch {
            isLoading = false
            loadError = error.localizedDescription
        }
    }

    private func fold(_ record: AppGroupRecordFfi) {
        if let idx = chats.firstIndex(where: { $0.groupIdHex == record.groupIdHex }) {
            chats[idx] = record
        } else {
            chats.append(record)
        }
        chats.sort(by: ChatsListViewModel.sortRule)
    }

    /// Order: pinned (none yet, placeholder), then by group name. Future:
    /// last-message-timestamp.
    private static let sortRule: (AppGroupRecordFfi, AppGroupRecordFfi) -> Bool = { a, b in
        let nameA = a.name.isEmpty ? a.groupIdHex : a.name
        let nameB = b.name.isEmpty ? b.groupIdHex : b.name
        return nameA.localizedCaseInsensitiveCompare(nameB) == .orderedAscending
    }
}

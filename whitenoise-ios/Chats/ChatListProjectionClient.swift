import MarmotKit

/// An open chat-list window, as `ChatsListViewModel` uses it.
nonisolated protocol ChatListWindowFeed: AnyObject, Sendable {
    func snapshot() -> ChatListWindowSnapshotFfi?
    /// Must end with a `CancellationError` when its task is cancelled; the
    /// view model awaits the reader before rebinding.
    func nextCancellable() async throws -> ChatListWindowSnapshotFfi?
    func setVisibleAnchor(sequence: UInt64, groupIdHex: String) async throws -> ChatListWindowSnapshotFfi
    func page(sequence: UInt64, direction: ChatListPageDirectionFfi, count: UInt32) async throws
        -> ChatListWindowSnapshotFfi
    func returnToTop(sequence: UInt64) async throws -> ChatListWindowSnapshotFfi
}

nonisolated extension ChatListWindowSubscription: ChatListWindowFeed {}

/// The Marmot reads behind `ChatsListViewModel`'s windowed list and single-row refresh.
protocol ChatListProjectionClient {
    func presentedChatListRow(accountRef: String, groupIdHex: String) async throws -> PresentedChatRowFfi?
    func openChatListWindowFeed(accountRef: String, view: ChatListViewFfi) async throws -> any ChatListWindowFeed
}

extension MarmotClient: ChatListProjectionClient {
    func openChatListWindowFeed(accountRef: String, view: ChatListViewFfi) async throws -> any ChatListWindowFeed {
        try await openChatListWindow(accountRef: accountRef, view: view)
    }
}

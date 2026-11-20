import MarmotKit

/// A cursor and the version of the collection it traverses. A returned page and its
/// continuation are installed together after the screen accepts the result.
@MainActor
struct AttachmentHistoryPager {
    struct Scope: Equatable {
        let account: String
        let accountID: String
        let group: String
        let runtimeGeneration: Int
        private let clientID: ObjectIdentifier

        init?(appState: AppState, group: String) {
            guard let account = appState.activeAccountRef, let accountID = appState.activeAccount?.accountIdHex,
                  let client = appState.client, let generation = appState.runtimeEventsGeneration else { return nil }
            self.account = account
            self.accountID = accountID
            self.group = group
            runtimeGeneration = generation
            clientID = ObjectIdentifier(client)
        }

        func currentClient(in appState: AppState) throws -> MarmotClient {
            try Task.checkCancellation()
            guard self == Scope(appState: appState, group: group), let client = appState.client else {
                throw CancellationError()
            }
            return client
        }

        /// A handoff lease outlives removal of its original slot. Verify that the slot
        /// is still readable before presenting the copy, including a removal during the lookup.
        func stillRetains(_ target: AttachmentLocalTargetFfi, in appState: AppState) async throws -> Bool {
            let before = try await version(in: appState)
            let client = try currentClient(in: appState)
            let assets = try await client.marmot.attachmentLocalAssets(accountRef: account, groupIdHex: group, targets: [target])
            guard assets.first?.reference != nil else { return false }
            let current = try await version(in: appState)
            return current.changeSince(previous: before) != .restartRequired
        }

        func version(in appState: AppState) async throws -> AttachmentHistoryVersion {
            let client = try currentClient(in: appState)
            let result = try await client.marmot.attachmentHistoryVersion(accountRef: account, groupIdHex: group)
            _ = try currentClient(in: appState)
            return result
        }
    }

    private(set) var baseline: AttachmentHistoryVersion?
    private(set) var cursor: AttachmentHistoryCursor?
    private(set) var canLoadMore = true

    /// Refresh from the newest page while retaining the original collection's deletion fence.
    func fromHead() -> Self { Self(baseline: baseline) }

    func readNext(in scope: Scope, using appState: AppState, isCurrent: () -> Bool,
                  onRestart: () -> Void) async throws -> (page: AttachmentPageFfi, next: Self) {
        var position = self
        for attempt in 0...1 {
            guard isCurrent() else { throw CancellationError() }
            let client = try scope.currentClient(in: appState)
            let result = try await client.marmot.attachmentHistoryPage(accountRef: scope.account,
                groupIdHex: scope.group, limit: 100, cursor: position.cursor)
            _ = try scope.currentClient(in: appState)
            guard isCurrent() else { throw CancellationError() }
            switch result {
            case .page(let page) where position.baseline.map({ page.version.changeSince(previous: $0) }) != .restartRequired:
                let next = Self(baseline: position.baseline ?? page.version, cursor: page.nextCursor,
                                canLoadMore: page.hasMore && page.nextCursor != nil)
                return (page, next)
            case .invalidLimit:
                throw AttachmentReadError.unavailable
            case .page, .restartRequired, .cursorMismatch:
                onRestart()
                guard attempt == 0 else { throw AttachmentReadError.stale }
                position = Self()
            }
        }
        throw AttachmentReadError.stale
    }
}

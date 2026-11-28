import Foundation
import MarmotKit

/// MDK's attachment-storage calls on one runtime.
nonisolated struct ManageStorageCalls: Sendable {
    var usage: @MainActor (_ accountRef: String) async throws -> AttachmentStorageUsageFfi
    var keepMedia: @MainActor (_ accountRef: String) async throws -> AttachmentKeepMediaFfi
    var chats: @MainActor (_ accountRef: String, _ limit: UInt32, _ cursor: ChatStorageCursor?)
        async throws -> ChatStoragePageFfi
    var attachments: @MainActor (_ accountRef: String, _ groupIdHex: String?, _ limit: UInt32,
                                 _ cursor: RetainedAttachmentsCursor?) async throws -> RetainedAttachmentsPageFfi
    var presentedRow: @MainActor (_ accountRef: String, _ groupIdHex: String) async throws -> PresentedChatRowFfi?
    var openPresentedRows: @MainActor (_ accountRef: String) async throws -> PresentedChatListSubscription
    var presentedRowsSnapshot: @MainActor (PresentedChatListSubscription) async -> PresentedChatListUpdateFfi?
    var clearAvatarCache: @MainActor (_ accountRef: String) async throws -> Void
    var removeOlder: @MainActor (_ accountRef: String, _ receivedBefore: UInt64, _ groupIdHex: String?)
        async throws -> UInt64
    var setKeepMedia: @MainActor (_ accountRef: String, _ keep: AttachmentKeepMediaFfi) async throws -> UInt64
    var removeChat: @MainActor (_ accountRef: String, _ groupIdHex: String) async throws -> UInt64
    var removeAttachment: @MainActor (_ accountRef: String, _ groupIdHex: String, _ target: AttachmentLocalTargetFfi)
        async throws -> Bool
    var plaintextHash: @MainActor (_ accountRef: String, _ groupIdHex: String, _ target: AttachmentLocalTargetFfi)
        async throws -> String?

    static func live(_ client: MarmotClient) -> ManageStorageCalls {
        ManageStorageCalls(
            usage: { try await client.attachmentStorageUsage(accountRef: $0) },
            keepMedia: { try await client.attachmentKeepMedia(accountRef: $0) },
            chats: { try await client.attachmentStorageByChat(accountRef: $0, limit: $1, cursor: $2) },
            attachments: {
                try await client.largestRetainedAttachments(accountRef: $0, groupIdHex: $1, limit: $2, cursor: $3)
            },
            presentedRow: { try await client.presentedChatListRow(accountRef: $0, groupIdHex: $1) },
            openPresentedRows: { try await client.openPresentedChatList(accountRef: $0, includeArchived: true) },
            presentedRowsSnapshot: { await client.presentedChatListSubscriptionSnapshot($0) },
            clearAvatarCache: { accountRef in
                // Drop decoded pictures and hold off new avatar demand while MDK clears the stored ones.
                AvatarCacheErasure.begin()
                defer { AvatarCacheErasure.end() }
                try await client.clearAvatarCache(accountRef: accountRef)
            },
            removeOlder: {
                try await client.removeAttachmentsOlderThan(accountRef: $0, receivedBefore: $1, groupIdHex: $2)
            },
            setKeepMedia: { try await client.setAttachmentKeepMedia(accountRef: $0, keep: $1) },
            removeChat: { try await client.removeChatAttachments(accountRef: $0, groupIdHex: $1) },
            removeAttachment: { try await client.removeRetainedAttachment(accountRef: $0, groupIdHex: $1, target: $2) },
            plaintextHash: {
                try await client.retainedAttachmentPlaintextHash(accountRef: $0, groupIdHex: $1, target: $2)
            }
        )
    }
}

/// One profile's Manage Storage state. Every read is bound to the account and
/// runtime it started on, and any removal starts every listing over.
@MainActor
@Observable
final class ManageStorageModel {
    // Avoid the isolated-deinit task-local crash on older Swift runtimes (including iOS 26.2).
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {}

    enum Scope: Hashable {
        case account
        case chat(String)

        var groupIdHex: String? {
            if case .chat(let groupIdHex) = self { return groupIdHex }
            return nil
        }
    }

    enum Operation: Equatable {
        case clearCache
        case removeOlder(Scope)
        case removeChat(String)
        case removeAttachment(String)
        case keepMedia

        /// Bulk removals report a count, not which plaintext they removed.
        var removesInBulk: Bool {
            switch self {
            case .removeOlder, .removeChat, .keepMedia: true
            case .clearCache, .removeAttachment: false
            }
        }

        /// A failed bulk call (nil) may still have removed some; one that reported none removed nothing.
        func dropsEveryDecryptedCopy(removed: UInt64?) -> Bool {
            removesInBulk && removed != 0
        }
    }

    struct ChatIdentity: Equatable {
        let title: String
        let seed: String
        let avatarAsset: AvatarAssetFfi?
    }

    typealias ChatPages = StoragePageList<ChatAttachmentUsageFfi, ChatStorageCursor>
    typealias AttachmentPages = StoragePageList<RetainedAttachmentSummaryFfi, RetainedAttachmentsCursor>

    /// The active profile's live runtime, while local foreground work may use it.
    struct Runtime {
        let accountRef: String
        let generation: Int
        let id: ObjectIdentifier
        let calls: ManageStorageCalls
    }

    /// One change's lease on the live runtime; suspension waits until `end`.
    struct Change {
        let runtimeID: ObjectIdentifier
        let calls: ManageStorageCalls
        let end: @MainActor () -> Void
    }

    struct Dependencies {
        var runtime: @MainActor (AppState) -> Runtime?
        var beginChange: @MainActor (AppState) throws -> Change
        /// Drops one removed file's decrypted copy (nil when MDK can't name it).
        var dropDecryptedCopy: @MainActor (_ plaintextHash: String?) async -> Void
        /// Drops every decrypted copy, for removals that can't name what they removed.
        var dropAllDecryptedMedia: @MainActor () async -> Void

        static let live = Dependencies(
            runtime: { appState in
                guard let accountRef = appState.activeAccountRef, appState.canUseRuntimeForLocalForegroundWork,
                      let client = appState.client else { return nil }
                return Runtime(accountRef: accountRef, generation: appState.runtimeGeneration,
                               id: ObjectIdentifier(client), calls: .live(client))
            },
            beginChange: { appState in
                let lifecycle = appState.runtimeLifecycle
                let lease = try lifecycle.beginForegroundRuntimeMutation()
                return Change(runtimeID: ObjectIdentifier(lease.client), calls: .live(lease.client),
                              end: { lifecycle.endForegroundRuntimeMutation(lease) })
            },
            dropDecryptedCopy: { plaintextHash in
                if let plaintextHash {
                    _ = await MessageMediaCache.removeCachedData(forPlaintextHashes: [plaintextHash])
                }
                AttachmentPresentationState.shared.invalidate()
            },
            dropAllDecryptedMedia: {
                // Open conversations then re-read through MDK.
                _ = await MessageMediaCache.purgeAllDecryptedMedia()
                AttachmentPresentationState.shared.invalidate()
            }
        )
    }

    private struct Context: Equatable {
        let accountRef: String
        let runtimeGeneration: Int
        let runtime: ObjectIdentifier

        init(_ runtime: Runtime) {
            accountRef = runtime.accountRef
            runtimeGeneration = runtime.generation
            self.runtime = runtime.id
        }
    }

    private(set) var usageRefresh = ManageStoragePresentation.UsageRefresh()
    /// Kept through removals so the picker doesn't blank; re-read after each.
    private var keepMediaRefresh = ManageStoragePresentation.KeepMedia.Refresh()
    private(set) var chats = ChatPages(id: \.groupIdHex)
    private(set) var chatsFailed = false
    private(set) var isLoadingChats = false
    private(set) var attachments: [Scope: AttachmentPages] = [:]
    private(set) var attachmentsFailed: Set<Scope> = []
    private(set) var loadingAttachments: Set<Scope> = []
    private(set) var operation: Operation?
    /// The last operation that failed, shown beside the control that started it.
    private(set) var failedOperation: Operation?
    /// Advances whenever the listings start over, so views can re-request pages.
    private(set) var epoch = 0
    /// Observed so presented updates re-render titles and avatars as they resolve.
    private var identities: [String: ChatIdentity] = [:]

    @ObservationIgnored private var context: Context?
    @ObservationIgnored private let dependencies: Dependencies
    #if DEBUG
    @ObservationIgnored private var isFixture = false
    #endif

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    var usage: ManageStoragePresentation.Usage? { usageRefresh.usage }
    var keepMedia: AttachmentKeepMediaFfi? { keepMediaRefresh.keep }
    var keepMediaFailed: Bool { keepMediaRefresh.failed }

    func identity(for groupIdHex: String) -> ChatIdentity {
        identities[groupIdHex]
            ?? ChatIdentity(title: L10n.string("Conversation unavailable"), seed: groupIdHex, avatarAsset: nil)
    }

    func chatUsage(_ groupIdHex: String) -> ChatAttachmentUsageFfi? {
        chats.items.first { $0.groupIdHex == groupIdHex }
    }

    func attachmentPages(_ scope: Scope) -> AttachmentPages {
        attachments[scope] ?? Self.emptyAttachmentPages()
    }

    /// Binds to the active profile's live runtime, starting over when either changed.
    func bind(using appState: AppState) async {
        #if DEBUG
        if isFixture { return }
        #endif
        guard let context = currentContext(appState) else {
            self.context = nil
            keepMediaRefresh = .init()
            reset()
            return
        }
        if context != self.context {
            self.context = context
            identities = [:]
            failedOperation = nil
            keepMediaRefresh = .init()
        }
        reset()
        await refreshUsage(using: appState)
        await refreshKeepMedia(using: appState)
        await loadMoreChats(using: appState)
    }

    func refreshKeepMedia(using appState: AppState) async {
        guard let context, let calls = calls(for: context, appState) else { return }
        let epoch = epoch
        do {
            let value = try await calls.keepMedia(context.accountRef)
            guard isCurrent(context, epoch: epoch, appState) else { return }
            keepMediaRefresh.succeeded(value)
        } catch {
            guard !(error is CancellationError), isCurrent(context, epoch: epoch, appState) else { return }
            keepMediaRefresh.failedToRefresh()
        }
    }

    func refreshUsage(using appState: AppState) async {
        guard let context, let calls = calls(for: context, appState) else { return }
        let epoch = epoch
        do {
            let value = try await calls.usage(context.accountRef)
            guard isCurrent(context, epoch: epoch, appState) else { return }
            usageRefresh.succeeded(ManageStoragePresentation.Usage(value))
        } catch {
            guard !(error is CancellationError), isCurrent(context, epoch: epoch, appState) else { return }
            usageRefresh.failedToRefresh()
        }
    }

    /// Follows the profile's presented chat list so listed chats pick up avatars
    /// once MDK acquires them, and renamed chats or nicknames. Runs until cancelled.
    func followPresentedRows(using appState: AppState) async {
        guard let context, let calls = calls(for: context, appState) else { return }
        var retryDelay = Duration.milliseconds(500)
        while !Task.isCancelled, currentContext(appState) == context {
            do {
                let subscription = try await calls.openPresentedRows(context.accountRef)
                guard let initial = await calls.presentedRowsSnapshot(subscription) else {
                    throw CancellationError()
                }
                guard !Task.isCancelled, currentContext(appState) == context else { return }
                var cursor = PresentedChatListCursor(initial: initial)
                applyPresentedRows(initial.snapshot.rows, using: appState)
                retryDelay = .milliseconds(500)
                while let update = try await subscription.nextCancellable() {
                    guard !Task.isCancelled, currentContext(appState) == context else { return }
                    // A new account-store epoch or generation needs a fresh subscription.
                    if cursor.requiresReopen(update) { break }
                    guard cursor.accept(update) else { continue }
                    applyPresentedRows(update.snapshot.rows, using: appState)
                }
            } catch is CancellationError {
                return
            } catch {
                // Titles and avatars stay as last read; try the subscription again.
            }
            guard (try? await Task.sleep(for: retryDelay)) != nil else { return }
            retryDelay = min(retryDelay * 2, .seconds(8))
        }
    }

    /// Updates only chats this screen lists, so avatar requests stay with rows on screen.
    func applyPresentedRows(_ rows: [PresentedChatRowFfi], using appState: AppState) {
        let listed = listedGroupIds
        for prepared in rows where listed.contains(prepared.row.groupIdHex) {
            let next = identity(for: prepared, appState)
            if identities[prepared.row.groupIdHex] != next {
                identities[prepared.row.groupIdHex] = next
            }
        }
    }

    private var listedGroupIds: Set<String> {
        var ids = Set(chats.items.map(\.groupIdHex))
        for pages in attachments.values {
            ids.formUnion(pages.items.map(\.groupIdHex))
        }
        return ids
    }

    func loadMoreChats(using appState: AppState) async {
        guard !isLoadingChats, chats.hasMore, let context, let calls = calls(for: context, appState) else { return }
        let epoch = epoch
        isLoadingChats = true
        defer { if self.epoch == epoch { isLoadingChats = false } }
        do {
            let page = try await calls.chats(context.accountRef, ManageStoragePresentation.pageLimit, chats.cursor)
            guard isCurrent(context, epoch: epoch, appState) else { return }
            await resolveIdentities(page.chats.map(\.groupIdHex), calls: calls, context: context, appState)
            guard isCurrent(context, epoch: epoch, appState) else { return }
            chats.append(page.chats, next: page.nextCursor)
            chatsFailed = false
        } catch {
            guard !(error is CancellationError), isCurrent(context, epoch: epoch, appState) else { return }
            chatsFailed = true
        }
    }

    func loadMoreAttachments(_ scope: Scope, using appState: AppState) async {
        let pages = attachmentPages(scope)
        guard !loadingAttachments.contains(scope), pages.hasMore, let context,
              let calls = calls(for: context, appState) else { return }
        let epoch = epoch
        loadingAttachments.insert(scope)
        defer { if self.epoch == epoch { loadingAttachments.remove(scope) } }
        do {
            let page = try await calls.attachments(context.accountRef, scope.groupIdHex,
                                                   ManageStoragePresentation.pageLimit, pages.cursor)
            guard isCurrent(context, epoch: epoch, appState) else { return }
            if scope == .account {
                await resolveIdentities(page.attachments.map(\.groupIdHex), calls: calls, context: context, appState)
                guard isCurrent(context, epoch: epoch, appState) else { return }
            }
            var updated = attachmentPages(scope)
            updated.append(page.attachments, next: page.nextCursor)
            attachments[scope] = updated
            attachmentsFailed.remove(scope)
        } catch {
            guard !(error is CancellationError), isCurrent(context, epoch: epoch, appState) else { return }
            attachmentsFailed.insert(scope)
        }
    }

    func clearCache(using appState: AppState) async {
        await perform(.clearCache, using: appState) { calls, accountRef in
            try await calls.clearAvatarCache(accountRef)
            return nil
        }
    }

    /// Removes before the exact cutoff the confirmation named.
    func removeOlder(than cutoff: ManageStoragePresentation.RemovalCutoff, in scope: Scope,
                     using appState: AppState) async {
        let receivedBefore = cutoff.receivedBefore
        await perform(.removeOlder(scope), using: appState) { calls, accountRef in
            try await calls.removeOlder(accountRef, receivedBefore, scope.groupIdHex)
        }
    }

    /// Returns how many attachments MDK removed, or nil when the change failed
    /// or the profile or runtime changed meanwhile.
    func setKeepMedia(_ keep: AttachmentKeepMediaFfi, using appState: AppState) async -> UInt64? {
        let started = context
        var removed: UInt64?
        await perform(.keepMedia, using: appState) { calls, accountRef in
            // Recorded before the re-read, which may fail and would otherwise leave the old window.
            var saved = false
            defer {
                if let started, currentContext(appState) == started {
                    keepMediaRefresh.changed(to: keep, saved: saved)
                }
            }
            removed = try await calls.setKeepMedia(accountRef, keep)
            saved = true
            return removed
        }
        guard let started, currentContext(appState) == started else { return nil }
        return removed
    }

    func removeAllAttachments(inChat groupIdHex: String, using appState: AppState) async {
        await perform(.removeChat(groupIdHex), using: appState) { calls, accountRef in
            try await calls.removeChat(accountRef, groupIdHex)
        }
    }

    /// An entry that no longer reads locally is already gone, and starting over drops its row.
    func remove(_ attachment: RetainedAttachmentSummaryFfi, using appState: AppState) async {
        let id = ManageStoragePresentation.attachmentID(attachment)
        await perform(.removeAttachment(id), using: appState) { calls, accountRef in
            guard try await calls.removeAttachment(accountRef, attachment.groupIdHex, attachment.target)
            else { throw AttachmentReadError.stale }
            // Like Downloads, drop only this file's decrypted copy. A copy that can't be
            // named or deleted stays a miss: never wipe every profile's media for one row.
            let hash = try await calls.plaintextHash(accountRef, attachment.groupIdHex, attachment.target)
            await dependencies.dropDecryptedCopy(hash)
            return nil
        }
    }

    /// `body` returns how many attachments MDK removed, when it reports a count.
    private func perform(_ operation: Operation, using appState: AppState,
                         _ body: (ManageStorageCalls, String) async throws -> UInt64?) async {
        guard self.operation == nil, let context, currentContext(appState) == context else { return }
        self.operation = operation
        failedOperation = nil
        defer { self.operation = nil }
        var attempted = false
        var removed: UInt64?
        do {
            let change = try dependencies.beginChange(appState)
            defer { change.end() }
            guard isCurrent(context, epoch: epoch, appState), change.runtimeID == context.runtime else {
                throw CancellationError()
            }
            attempted = true
            removed = try await body(change.calls, context.accountRef)
        } catch {
            if currentContext(appState) == context { failedOperation = operation }
        }
        if attempted, operation.dropsEveryDecryptedCopy(removed: removed) {
            await dependencies.dropAllDecryptedMedia()
        }
        guard currentContext(appState) == context else { return }
        await bind(using: appState)
    }

    private func reset() {
        epoch &+= 1
        usageRefresh = ManageStoragePresentation.UsageRefresh()
        chats = ChatPages(id: \.groupIdHex)
        chatsFailed = false
        isLoadingChats = false
        attachments = [:]
        attachmentsFailed = []
        loadingAttachments = []
    }

    private func resolveIdentities(_ groupIds: [String], calls: ManageStorageCalls, context: Context,
                                   _ appState: AppState) async {
        for groupIdHex in Set(groupIds) where identities[groupIdHex] == nil {
            do {
                let row = try await calls.presentedRow(context.accountRef, groupIdHex)
                guard currentContext(appState) == context else { return }
                identities[groupIdHex] = row.map { identity(for: $0, appState) }
                    ?? identity(for: groupIdHex)
            } catch {
                // Read again on the next pass; the fallback title stands in meanwhile.
                if error is CancellationError { return }
            }
        }
    }

    private func identity(for prepared: PresentedChatRowFfi, _ appState: AppState) -> ChatIdentity {
        let nickname = prepared.row.conversationKind == .direct
            ? prepared.presentation.peerId.flatMap { appState.contactNickname(forAccountIdHex: $0) }
            : nil
        let display = SelectedChatPresentation.display(prepared.presentation, row: prepared.row, nickname: nickname)
        // Pending invitations keep avatar egress suppressed.
        return ChatIdentity(title: display.title, seed: display.avatarSeed,
                            avatarAsset: prepared.row.pendingConfirmation ? nil : prepared.avatarAsset)
    }

    private func currentContext(_ appState: AppState) -> Context? {
        dependencies.runtime(appState).map(Context.init)
    }

    private func calls(for context: Context, _ appState: AppState) -> ManageStorageCalls? {
        guard let runtime = dependencies.runtime(appState), Context(runtime) == context else { return nil }
        return runtime.calls
    }

    private func isCurrent(_ context: Context, epoch: Int, _ appState: AppState) -> Bool {
        !Task.isCancelled && self.epoch == epoch && currentContext(appState) == context
    }

    private static func emptyAttachmentPages() -> AttachmentPages {
        AttachmentPages(id: ManageStoragePresentation.attachmentID)
    }
}

#if DEBUG
extension ManageStorageModel {
    /// Fixed figures for previews and offline layout checks. It never binds a
    /// runtime, so nothing reaches MDK.
    static func fixture(usage: AttachmentStorageUsageFfi,
                        chats: [(usage: ChatAttachmentUsageFfi, title: String)],
                        attachments: [RetainedAttachmentSummaryFfi],
                        keepMedia: AttachmentKeepMediaFfi = .forever) -> ManageStorageModel {
        let model = ManageStorageModel()
        model.isFixture = true
        model.usageRefresh.succeeded(ManageStoragePresentation.Usage(usage))
        model.keepMediaRefresh.succeeded(keepMedia)
        for chat in chats {
            model.identities[chat.usage.groupIdHex] = ChatIdentity(title: chat.title, seed: chat.usage.groupIdHex,
                                                                   avatarAsset: nil)
        }
        model.chats.append(chats.map(\.usage), next: nil)
        var account = emptyAttachmentPages()
        account.append(attachments, next: nil)
        model.attachments[.account] = account
        for groupIdHex in Set(attachments.map(\.groupIdHex)) {
            var pages = emptyAttachmentPages()
            pages.append(attachments.filter { $0.groupIdHex == groupIdHex }, next: nil)
            model.attachments[.chat(groupIdHex)] = pages
        }
        return model
    }
}
#endif

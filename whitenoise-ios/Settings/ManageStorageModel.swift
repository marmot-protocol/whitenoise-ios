import Foundation
import MarmotKit

/// One profile's Manage Storage state. Every read is bound to the account and
/// runtime it started on, and any removal starts every listing over.
@MainActor
@Observable
final class ManageStorageModel {
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
    }

    struct ChatIdentity: Equatable {
        let title: String
        let seed: String
        let avatarAsset: AvatarAssetFfi?
    }

    typealias ChatPages = StoragePageList<ChatAttachmentUsageFfi, ChatStorageCursor>
    typealias AttachmentPages = StoragePageList<RetainedAttachmentSummaryFfi, RetainedAttachmentsCursor>

    private struct Context: Equatable {
        let accountRef: String
        let runtimeGeneration: Int
        let client: ObjectIdentifier
    }

    private(set) var usage: ManageStoragePresentation.Usage?
    private(set) var usageFailed = false
    private(set) var chats = ChatPages(id: \.groupIdHex)
    private(set) var chatsFailed = false
    private(set) var isLoadingChats = false
    private(set) var attachments: [Scope: AttachmentPages] = [:]
    private(set) var attachmentsFailed: Set<Scope> = []
    private(set) var loadingAttachments: Set<Scope> = []
    private(set) var operation: Operation?
    /// The last operation that failed, shown beside the control that started it.
    private(set) var failedOperation: Operation?
    /// Advances on every usage read, so a poll continues while figures stay the same.
    private(set) var usageRevision = 0
    /// Advances whenever the listings start over, so views can re-request pages.
    private(set) var epoch = 0

    @ObservationIgnored private var identities: [String: ChatIdentity] = [:]
    @ObservationIgnored private var context: Context?
    #if DEBUG
    @ObservationIgnored private var isFixture = false
    #endif

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
            reset()
            return
        }
        if context != self.context {
            self.context = context
            identities = [:]
            failedOperation = nil
        }
        reset()
        await refreshUsage(using: appState)
        await loadMoreChats(using: appState)
    }

    func refreshUsage(using appState: AppState) async {
        guard let context, let client = client(for: context, appState) else { return }
        let epoch = epoch
        do {
            let value = try await client.attachmentStorageUsage(accountRef: context.accountRef)
            guard isCurrent(context, epoch: epoch, appState) else { return }
            usage = ManageStoragePresentation.Usage(value)
            usageFailed = false
            usageRevision &+= 1
        } catch {
            guard !(error is CancellationError), isCurrent(context, epoch: epoch, appState) else { return }
            usageFailed = true
        }
    }

    func loadMoreChats(using appState: AppState) async {
        guard !isLoadingChats, chats.hasMore, let context, let client = client(for: context, appState) else { return }
        let epoch = epoch
        isLoadingChats = true
        defer { if self.epoch == epoch { isLoadingChats = false } }
        do {
            let page = try await client.attachmentStorageByChat(accountRef: context.accountRef,
                limit: ManageStoragePresentation.pageLimit, cursor: chats.cursor)
            guard isCurrent(context, epoch: epoch, appState) else { return }
            await resolveIdentities(page.chats.map(\.groupIdHex), client: client, context: context, appState)
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
              let client = client(for: context, appState) else { return }
        let epoch = epoch
        loadingAttachments.insert(scope)
        defer { if self.epoch == epoch { loadingAttachments.remove(scope) } }
        do {
            let page = try await client.largestRetainedAttachments(accountRef: context.accountRef,
                groupIdHex: scope.groupIdHex, limit: ManageStoragePresentation.pageLimit, cursor: pages.cursor)
            guard isCurrent(context, epoch: epoch, appState) else { return }
            if scope == .account {
                await resolveIdentities(page.attachments.map(\.groupIdHex), client: client, context: context, appState)
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
        await perform(.clearCache, using: appState) { client, accountRef in
            try await client.clearAvatarCache(accountRef: accountRef)
        }
    }

    func removeOlder(_ age: ManageStoragePresentation.RemovalAge, in scope: Scope, now: Date = Date(),
                     using appState: AppState) async {
        let receivedBefore = age.receivedBefore(now: now, calendar: .current)
        await perform(.removeOlder(scope), using: appState) { client, accountRef in
            _ = try await client.removeAttachmentsOlderThan(accountRef: accountRef,
                receivedBefore: receivedBefore, groupIdHex: scope.groupIdHex)
        }
    }

    func removeAllAttachments(inChat groupIdHex: String, using appState: AppState) async {
        await perform(.removeChat(groupIdHex), using: appState) { client, accountRef in
            _ = try await client.removeChatAttachments(accountRef: accountRef, groupIdHex: groupIdHex)
        }
    }

    /// An entry that no longer reads locally is already gone, and starting over drops its row.
    func remove(_ attachment: RetainedAttachmentSummaryFfi, using appState: AppState) async {
        let id = ManageStoragePresentation.attachmentID(attachment)
        await perform(.removeAttachment(id), using: appState) { client, accountRef in
            guard try await client.removeRetainedAttachment(accountRef: accountRef,
                groupIdHex: attachment.groupIdHex, target: attachment.target)
            else { throw AttachmentReadError.stale }
        }
    }

    private func perform(_ operation: Operation, using appState: AppState,
                         _ body: (MarmotClient, String) async throws -> Void) async {
        guard self.operation == nil, let context, currentContext(appState) == context else { return }
        self.operation = operation
        failedOperation = nil
        defer { self.operation = nil }
        var attempted = false
        do {
            let lease = try appState.runtimeLifecycle.beginForegroundRuntimeMutation()
            defer { appState.runtimeLifecycle.endForegroundRuntimeMutation(lease) }
            guard isCurrent(context, epoch: epoch, appState), lease.client === appState.client else {
                throw CancellationError()
            }
            attempted = true
            try await body(lease.client, context.accountRef)
        } catch {
            if currentContext(appState) == context { failedOperation = operation }
        }
        // A failed bulk call may still have removed some attachments.
        if attempted, operation != .clearCache {
            await Self.invalidateHostMedia()
        }
        guard currentContext(appState) == context else { return }
        await bind(using: appState)
    }

    /// Bulk removals report counts, not plaintext hashes, so drop every decrypted
    /// copy; open conversations then re-read through MDK.
    private static func invalidateHostMedia() async {
        _ = await MessageMediaCache.purgeAllDecryptedMedia()
        AttachmentPresentationState.shared.invalidate()
    }

    private func reset() {
        epoch &+= 1
        usage = nil
        usageFailed = false
        chats = ChatPages(id: \.groupIdHex)
        chatsFailed = false
        isLoadingChats = false
        attachments = [:]
        attachmentsFailed = []
        loadingAttachments = []
    }

    private func resolveIdentities(_ groupIds: [String], client: MarmotClient, context: Context,
                                   _ appState: AppState) async {
        for groupIdHex in Set(groupIds) where identities[groupIdHex] == nil {
            do {
                let row = try await client.presentedChatListRow(accountRef: context.accountRef, groupIdHex: groupIdHex)
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
        guard let accountRef = appState.activeAccountRef, appState.canUseRuntimeForLocalForegroundWork,
              let client = appState.client else { return nil }
        return Context(accountRef: accountRef, runtimeGeneration: appState.runtimeGeneration,
                       client: ObjectIdentifier(client))
    }

    private func client(for context: Context, _ appState: AppState) -> MarmotClient? {
        guard currentContext(appState) == context else { return nil }
        return appState.client
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
                        attachments: [RetainedAttachmentSummaryFfi]) -> ManageStorageModel {
        let model = ManageStorageModel()
        model.isFixture = true
        model.usage = ManageStoragePresentation.Usage(usage)
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

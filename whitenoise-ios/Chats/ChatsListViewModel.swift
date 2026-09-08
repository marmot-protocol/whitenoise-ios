import Foundation
import Observation
import OSLog
import MarmotKit

/// Session cache for the small piece of roster state a DM row needs to resolve
/// through the already-cached profile directory. It is account-scoped because
/// the same MLS group id must never be interpreted through another profile's
/// roster, and bounded because chat-list view models can live for the app
/// session while users switch among several local profiles.
struct ChatListDirectPeerCache {
    private let maxAccounts: Int
    private let maxGroupsPerAccount: Int
    private var peersByAccount: [String: [String: String]] = [:]
    private var accountRecency: [String] = []

    init(maxAccounts: Int = 4, maxGroupsPerAccount: Int = 512) {
        self.maxAccounts = max(1, maxAccounts)
        self.maxGroupsPerAccount = max(1, maxGroupsPerAccount)
    }

    mutating func store(
        accountRef: String,
        peersByGroupId: [String: String],
        rowsByGroupId: [String: ChatListRowFfi]
    ) {
        // A rapid account switch can cancel the replacement snapshot before
        // any rows arrive. Keep the last useful mapping instead of replacing
        // it with an empty partial bind.
        guard !rowsByGroupId.isEmpty else { return }
        let retained = peersByGroupId
            .filter { groupId, peerId in
                !peerId.isEmpty
                    && rowsByGroupId[groupId]?.conversationKind == .direct
            }
            .sorted { lhs, rhs in
                let lhsActivity = rowsByGroupId[lhs.key]?.activitySortAt ?? 0
                let rhsActivity = rowsByGroupId[rhs.key]?.activitySortAt ?? 0
                if lhsActivity != rhsActivity {
                    return lhsActivity > rhsActivity
                }
                return lhs.key < rhs.key
            }
            .prefix(maxGroupsPerAccount)
        peersByAccount[accountRef] = Dictionary(
            uniqueKeysWithValues: retained.map { ($0.key, $0.value) }
        )
        touch(accountRef)
        while accountRecency.count > maxAccounts {
            let evicted = accountRecency.removeFirst()
            peersByAccount[evicted] = nil
        }
    }

    mutating func restore(accountRef: String) -> [String: String] {
        guard let peers = peersByAccount[accountRef] else { return [:] }
        touch(accountRef)
        return peers
    }

    private mutating func touch(_ accountRef: String) {
        accountRecency.removeAll { $0 == accountRef }
        accountRecency.append(accountRef)
    }
}

/// Owns the live list of chats for the currently active account. The list is
/// now driven by Marmot's durable chat-list projection instead of rebuilding
/// previews from account-wide message snapshots on every appearance.
@Observable
@MainActor
final class ChatsListViewModel {
    private static let performanceSignposter = OSSignposter(
        subsystem: "dev.ipf.whitenoise.ios",
        category: "Performance"
    )

    struct Item: Equatable, Identifiable {
        let row: ChatListRowFfi
        let avatarURL: URL?
        let avatarSeed: String
        let title: String
        let isDirectMessage: Bool?
        let directPeerAccountIdHex: String?
        /// Who invited this account, for rows still awaiting a reply. Marmot's
        /// chat-list row carries no welcomer, so this is enriched separately.
        let inviterAccountIdHex: String?
        let isMuted: Bool
        let previewText: String?
        let draftPreview: String?
        let searchHaystack: String
        let leaveRequestPending: Bool

        init(
            row: ChatListRowFfi,
            avatarURL: URL?,
            avatarSeed: String? = nil,
            title: String,
            isDirectMessage: Bool? = nil,
            directPeerAccountIdHex: String? = nil,
            inviterAccountIdHex: String? = nil,
            isMuted: Bool = false,
            leaveRequestPending: Bool = false,
            draftSummary: MessageDraftSummaryFfi? = nil,
            mentionDisplayName: MarkdownMentionResolver? = nil,
            systemEventNaming: GroupSystemEventNaming = .shortIdentities
        ) {
            let previewText = Self.sanitizedPreview(
                from: row.lastMessage,
                mentionDisplayName: mentionDisplayName,
                systemEventNaming: systemEventNaming
            )
            self.row = row
            self.avatarURL = avatarURL
            self.avatarSeed = avatarSeed ?? row.groupIdHex
            self.title = title
            self.isDirectMessage = isDirectMessage
            self.directPeerAccountIdHex = directPeerAccountIdHex
            self.inviterAccountIdHex = inviterAccountIdHex
            self.isMuted = isMuted
            self.leaveRequestPending = leaveRequestPending
            self.previewText = previewText
            self.draftPreview = ConversationDraftPreview.text(
                from: draftSummary,
                mentionDisplayName: mentionDisplayName
            )
            self.searchHaystack = Self.makeSearchHaystack(
                title: title,
                previewText: previewText,
                draftPreview: self.draftPreview
            )
        }

        var id: String { row.groupIdHex }
        var unreadCount: UInt64 { row.unreadCount }
        var hasUnread: Bool { row.hasUnread }
        var unreadMentionCount: UInt64 { row.unreadMentionCount }
        var hasUnreadMention: Bool { row.unreadMention || row.unreadMentionCount > 0 }
        var isPinned: Bool { row.pinned }
        var isArchived: Bool { row.archived }
        var isDisbanding: Bool { row.disbanding }
        var isDisbanded: Bool { row.lifecycleState == .disbanded }
        var selfMembership: SelfMembershipFfi { row.selfMembership }
        var isActiveMember: Bool {
            !leaveRequestPending
                && GroupManagementPresentation.isActiveChatListMember(row.selfMembership)
        }
        var firstUnreadMessageIdHex: String? { row.firstUnreadMessageIdHex }
        var lastMessage: ChatListMessagePreviewFfi? { row.lastMessage }
        var projectedGroup: AppGroupRecordFfi {
            AppGroupRecordFfi(
                groupIdHex: row.groupIdHex,
                endpoint: "",
                name: ContentSanitizer.groupName(row.groupName) ?? title,
                description: "",
                admins: [],
                relays: [],
                nostrGroupIdHex: "",
                avatarUrl: row.avatarUrl,
                avatarDim: nil,
                avatarThumbhash: nil,
                imageHashHex: row.avatar?.imageHashHex,
                encryptedMedia: AppGroupEncryptedMediaComponentFfi(
                    componentId: 0,
                    component: "",
                    required: false,
                    version: nil,
                    mediaFormat: "",
                    allowedLocatorKinds: [],
                    defaultBlobEndpoints: []
                ),
                archived: row.archived,
                pendingConfirmation: row.pendingConfirmation,
                selfMembership: selfMembership,
                leaveRequestPending: row.leaveRequestPending,
                leaveRequestedAtMs: row.leaveRequestedAtMs,
                disbanding: row.disbanding,
                disbandRequest: row.disbandRequest,
                disbanded: row.lifecycleState == .disbanded,
                welcomerAccountIdHex: inviterAccountIdHex,
                viaWelcomeMessageIdHex: nil
            )
        }

        static func sanitizedTitle(for row: ChatListRowFfi) -> String {
            if let name = ContentSanitizer.groupName(row.groupName) { return name }
            if let name = ContentSanitizer.groupName(row.title) { return name }
            return IdentityFormatter.short(row.groupIdHex)
        }

        private static func sanitizedPreview(
            from preview: ChatListMessagePreviewFfi?,
            mentionDisplayName: MarkdownMentionResolver?,
            systemEventNaming: GroupSystemEventNaming
        ) -> String? {
            preview.flatMap {
                ContentSanitizer.compactSingleLine(
                    MessagePreview.body(
                        $0,
                        mentionDisplayName: mentionDisplayName,
                        systemEventNaming: systemEventNaming
                    ),
                    maxLength: 140
                )
            }
        }

        private static func makeSearchHaystack(
            title: String,
            previewText: String?,
            draftPreview: String?
        ) -> String {
            [title, previewText, draftPreview]
                .compactMap { $0 }
                .joined(separator: " ")
                .localizedLowercase
        }
    }

    private(set) var items: [Item] = []
    private(set) var archivedItems: [Item] = []
    /// Advances only when the published row collections actually change.
    /// Views can key derived projections from this instead of rebuilding them
    /// repeatedly during a single SwiftUI body evaluation.
    private(set) var visibleRowsRevision = 0
    private(set) var isLoading: Bool = false
    private(set) var loadError: String?

    private weak var appState: AppState?
    @ObservationIgnored private let draftStore: ConversationDraftStore
    private var chatListTask: Task<Void, Never>?
    private var chatListTaskID: UUID?
    private var avatarURLTask: Task<Void, Never>?
    private var avatarEnrichmentTaskID: UUID?
    private var pendingChatListUpdateTask: Task<Void, Never>?
    private var currentAccount: String?
    private var rowByGroupId: [String: ChatListRowFfi] = [:]
    private var itemByGroupId: [String: Item] = [:]
    private var pendingChatListRowsByGroupId: [String: ChatListRowFfi] = [:]
    private var avatarURLByGroupId: [String: String] = [:]
    private var directPeerAccountIdByGroupId: [String: String] = [:]
    private var inviterAccountIdByGroupId: [String: String] = [:]
    private var inviterLookupCompletedGroupIds: Set<String> = []
    private var inviterLookupFailureCountByGroupId: [String: Int] = [:]
    private var retainedDirectPeerCache = ChatListDirectPeerCache()
    private var groupDetailsCache: [String: GroupDetailsFfi] = [:]
    private var directPeerLookupCompletedGroupIds: Set<String> = []
    private var pendingDirectPeerRefreshGroupIds: Set<String> = []
    @ObservationIgnored private var defersPinOrderSnapshots = false
    @ObservationIgnored private var deferredPinOrderSnapshot: [ChatListRowFfi]?
    @ObservationIgnored private var pinOrderUITransitionID: UUID?

    private static let chatListUpdateCoalescingDelayNanoseconds: UInt64 = 16_000_000
    private static let liveSubscriptionInitialRetryDelayNanoseconds: UInt64 = 500_000_000
    private static let liveSubscriptionMaximumRetryDelayNanoseconds: UInt64 = 8_000_000_000
    private static let rowEnrichmentRetryDelayNanoseconds: UInt64 = 1_000_000_000
    private static let inviterEnrichmentBatchLimit = 8
    private nonisolated static let inviterLookupFailureLimit = 3

    #if DEBUG
    @ObservationIgnored var mentionDisplayNameForTesting: MarkdownMentionResolver?
    @ObservationIgnored private(set) var publishedItemsMutationCountForTesting = 0
    #endif

    init(appState: AppState) {
        self.appState = appState
        self.draftStore = appState.conversationDraftStore
    }

    isolated deinit {
        chatListTask?.cancel()
        avatarURLTask?.cancel()
        pendingChatListUpdateTask?.cancel()
    }

    /// Begin (or rebind, when `accountRef` changes) the projected chat-list
    /// subscription.
    func bind(accountRef: String?, force: Bool = false) async {
        if currentAccount == accountRef, !force { return }
        chatListTask?.cancel()
        chatListTask = nil
        chatListTaskID = nil
        avatarURLTask?.cancel()
        avatarURLTask = nil
        avatarEnrichmentTaskID = nil
        pendingChatListUpdateTask?.cancel()
        pendingChatListUpdateTask = nil
        defersPinOrderSnapshots = false
        deferredPinOrderSnapshot = nil
        pinOrderUITransitionID = nil
        if currentAccount != accountRef {
            if let currentAccount {
                retainedDirectPeerCache.store(
                    accountRef: currentAccount,
                    peersByGroupId: directPeerAccountIdByGroupId,
                    rowsByGroupId: rowByGroupId
                )
            }
            let hadPublishedRows = !items.isEmpty || !archivedItems.isEmpty
            rowByGroupId = [:]
            itemByGroupId = [:]
            items = []
            archivedItems = []
            if hadPublishedRows {
                visibleRowsRevision &+= 1
            }
            pendingChatListRowsByGroupId = [:]
            avatarURLByGroupId = [:]
            directPeerAccountIdByGroupId = accountRef.map {
                retainedDirectPeerCache.restore(accountRef: $0)
            } ?? [:]
            groupDetailsCache = [:]
            inviterAccountIdByGroupId = [:]
            inviterLookupCompletedGroupIds = []
            inviterLookupFailureCountByGroupId = [:]
            directPeerLookupCompletedGroupIds = []
            pendingDirectPeerRefreshGroupIds = []
        }
        loadError = nil

        guard let accountRef else {
            currentAccount = nil
            return
        }
        await draftStore.loadIfNeeded(accountRef: accountRef)
        guard !Task.isCancelled else { return }
        guard let appState, appState.canUseRuntimeForForegroundWork else { return }
        currentAccount = accountRef
        isLoading = true
        startLiveUpdates(accountRef: accountRef)
    }

    private func startLiveUpdates(accountRef: String) {
        guard let appState else { return }
        let taskID = UUID()
        chatListTaskID = taskID
        chatListTask = Task { @MainActor [weak self, weak appState] in
            defer { self?.finishChatListTask(taskID: taskID) }
            var retryDelay = Self.liveSubscriptionInitialRetryDelayNanoseconds
            while !Task.isCancelled {
                do {
                    guard let appState, appState.canUseRuntimeForForegroundWork else { return }
                    let client = try appState.currentMarmotClient()
                    let chatListSub = try await client.subscribeChatList(
                        accountRef: accountRef,
                        includeArchived: true
                    )
                    guard !Task.isCancelled,
                          self?.ownsChatListTask(taskID: taskID, accountRef: accountRef) == true
                    else { return }
                    let snapshot = await client.chatListSubscriptionSnapshot(chatListSub)
                    guard !Task.isCancelled,
                          appState.canUseRuntimeForForegroundWork,
                          self?.ownsChatListTask(taskID: taskID, accountRef: accountRef) == true
                    else { return }
                    self?.loadError = nil
                    self?.applyChatListSnapshot(snapshot)
                    self?.isLoading = false

                    for await update in SubscriptionDriver.chatListUpdates(chatListSub) {
                        guard !Task.isCancelled,
                              appState.canUseRuntimeForForegroundWork,
                              self?.ownsChatListTask(taskID: taskID, accountRef: accountRef) == true
                        else { return }
                        retryDelay = Self.liveSubscriptionInitialRetryDelayNanoseconds
                        self?.applyChatListUpdate(update)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled,
                          appState?.canUseRuntimeForForegroundWork == true,
                          self?.ownsChatListTask(taskID: taskID, accountRef: accountRef) == true
                    else { return }
                    if self?.rowByGroupId.isEmpty == true {
                        self?.loadError = error.localizedDescription
                    }
                    self?.isLoading = false
                }
                guard !Task.isCancelled,
                      appState?.canUseRuntimeForForegroundWork == true,
                      self?.ownsChatListTask(taskID: taskID, accountRef: accountRef) == true
                else { return }
                do {
                    try await Task.sleep(nanoseconds: retryDelay)
                } catch {
                    return
                }
                retryDelay = Self.nextLiveSubscriptionRetryDelay(after: retryDelay)
            }
        }
    }

    /// Re-pull the durable rows from local storage. This keeps pull-to-refresh
    /// and list reappearance useful without doing an account-wide message scan.
    func refreshRows() async {
        guard let accountRef = currentAccount,
              let appState,
              appState.canUseRuntimeForForegroundWork
        else { return }
        await draftStore.loadIfNeeded(accountRef: accountRef)
        do {
            let snapshot = try await appState.currentMarmotClient().chatList(
                accountRef: accountRef,
                includeArchived: true
            )
            guard currentAccount == accountRef else { return }
            applyChatListSnapshot(snapshot)
        } catch is CancellationError {
            return
        } catch {
            // Non-fatal: subscription updates remain authoritative.
        }
    }

    /// Resolves one just-created or deep-linked destination directly from the
    /// durable keyed projection instead of waiting for a broad subscription
    /// update to happen to deliver it.
    func refreshRow(groupIdHex: String) async {
        guard let accountRef = currentAccount, let appState else { return }
        if let createdRow = appState.createdChatListRow(
            accountRef: accountRef,
            groupIdHex: groupIdHex
        ) {
            applyChatListRow(createdRow)
            return
        }
        guard
              appState.canUseRuntimeForLocalForegroundWork
        else { return }
        do {
            guard let row = try await appState.currentMarmotClient().chatListRow(
                accountRef: accountRef,
                groupIdHex: groupIdHex
            ), currentAccount == accountRef
            else { return }
            applyChatListRow(row)
        } catch is CancellationError {
            return
        } catch {
            // The subscription remains authoritative and may still deliver it.
        }
    }

    /// O(1) lookup for a chat-list item by its group id, backed by the
    /// id-keyed `itemByGroupId` map. Views that resolve a single row by id
    /// (e.g. deep-link destinations) should use this instead of scanning the
    /// published `items`/`archivedItems` arrays in `body`.
    func item(groupIdHex: String) -> Item? {
        itemByGroupId[groupIdHex]
    }

    /// Forwarding should use the same live, enriched projection as the chat
    /// list so newly-arrived rows and resolved direct-chat names are preserved.
    func forwardDestinations(excludingGroupIdHex currentGroupIdHex: String) -> [MessageForwardDestination] {
        MessageForwardDestinationPresentation.destinations(
            from: Array(itemByGroupId.values),
            excludingGroupIdHex: currentGroupIdHex
        )
    }

    func applyChatListSnapshot(
        _ snapshot: [ChatListRowFfi],
        mergingPendingRows: Bool = true
    ) {
        let timing = appState?.productAnalytics.beginTiming()
        defer { appState?.productAnalytics.recordTiming(.inboxSnapshot, since: timing) }

        loadError = nil
        pendingChatListUpdateTask?.cancel()
        pendingChatListUpdateTask = nil
        let mergedSnapshot = mergingPendingRows
            ? Self.mergingSnapshot(
                snapshot,
                withPendingRows: Array(pendingChatListRowsByGroupId.values)
            )
            : snapshot
        pendingChatListRowsByGroupId = [:]
        let previousRows = rowByGroupId
        let previousItems = itemByGroupId
        var nextRows: [String: ChatListRowFfi] = [:]
        var nextItems: [String: Item] = [:]
        var changed = false
        let muteLookup = currentMuteLookup()
        for row in mergedSnapshot {
            updateCachedGroupDetails(with: row)
            let item = makeItem(for: row, muteLookup: muteLookup)
            nextRows[row.groupIdHex] = row
            nextItems[row.groupIdHex] = item
            if previousRows[row.groupIdHex] != row || previousItems[row.groupIdHex] != item {
                changed = true
            }
        }
        if Set(previousRows.keys) != Set(nextRows.keys) {
            changed = true
        }
        rowByGroupId = nextRows
        itemByGroupId = nextItems
        pruneEnrichmentCaches(toSurviving: Set(rowByGroupId.keys))
        if changed {
            publishItems()
        }
        scheduleRowEnrichment(for: mergedSnapshot)
    }

    /// Applies Marmot's complete authoritative pin order without waiting for
    /// the matching subscription snapshot to make its round trip through the
    /// row coalescer.
    func applyPinnedOrder(_ orderedGroupIds: [String]) {
        let positions = Dictionary(
            uniqueKeysWithValues: orderedGroupIds.enumerated().map { ($0.element, UInt32($0.offset)) }
        )
        var changed = false
        let muteLookup = currentMuteLookup()

        for groupId in Array(rowByGroupId.keys) {
            guard var row = rowByGroupId[groupId] else { continue }
            let position = positions[groupId]
            let pinned = position != nil
            guard row.pinned != pinned || row.pinnedPosition != position else { continue }

            row.pinned = pinned
            row.pinnedPosition = position
            rowByGroupId[groupId] = row
            itemByGroupId[groupId] = makeItem(for: row, muteLookup: muteLookup)
            changed = true
        }

        if changed {
            publishItems()
        }
    }

    static func mergingSnapshot(
        _ snapshot: [ChatListRowFfi],
        withPendingRows pendingRows: [ChatListRowFfi]
    ) -> [ChatListRowFfi] {
        var rowsByGroupId: [String: ChatListRowFfi] = [:]
        for row in snapshot {
            rowsByGroupId[row.groupIdHex] = row
        }
        var appendedGroupIds: [String] = []
        for pending in pendingRows {
            if let snapshotRow = rowsByGroupId[pending.groupIdHex] {
                if pending.updatedAt >= snapshotRow.updatedAt {
                    rowsByGroupId[pending.groupIdHex] = pending
                }
            } else {
                rowsByGroupId[pending.groupIdHex] = pending
                appendedGroupIds.append(pending.groupIdHex)
            }
        }
        return snapshot.compactMap { rowsByGroupId[$0.groupIdHex] }
            + appendedGroupIds.compactMap { rowsByGroupId[$0] }
    }

    /// Intersect the parallel enrichment caches/sets down to the surviving
    /// group-id key set after a full snapshot rebuild. A snapshot never calls
    /// `removeChatListRow`, so groups that drop out of the list between
    /// snapshots would otherwise strand entries in these collections for the
    /// lifetime of the account binding. Mirrors `removeChatListRow`'s per-group
    /// cleanup for every group absent from the snapshot.
    private func pruneEnrichmentCaches(toSurviving surviving: Set<String>) {
        groupDetailsCache = Self.intersecting(groupDetailsCache, with: surviving)
        avatarURLByGroupId = Self.intersecting(avatarURLByGroupId, with: surviving)
        directPeerAccountIdByGroupId = Self.intersecting(directPeerAccountIdByGroupId, with: surviving)
        inviterAccountIdByGroupId = Self.intersecting(inviterAccountIdByGroupId, with: surviving)
        inviterLookupCompletedGroupIds = Self.intersecting(
            inviterLookupCompletedGroupIds,
            with: surviving
        )
        inviterLookupFailureCountByGroupId = Self.intersecting(
            inviterLookupFailureCountByGroupId,
            with: surviving
        )
        directPeerLookupCompletedGroupIds = Self.intersecting(
            directPeerLookupCompletedGroupIds,
            with: surviving
        )
        pendingDirectPeerRefreshGroupIds = Self.intersecting(
            pendingDirectPeerRefreshGroupIds,
            with: surviving
        )
    }

    /// Pure helper: keep only the dictionary entries whose key survives.
    static func intersecting<Value>(
        _ cache: [String: Value],
        with surviving: Set<String>
    ) -> [String: Value] {
        cache.filter { surviving.contains($0.key) }
    }

    /// Pure helper: keep only the set members that survive.
    static func intersecting(
        _ ids: Set<String>,
        with surviving: Set<String>
    ) -> Set<String> {
        ids.intersection(surviving)
    }

    func applyChatListRow(_ row: ChatListRowFfi) {
        pendingChatListRowsByGroupId[row.groupIdHex] = nil
        if storeRow(row) {
            publishItems()
        }
        scheduleRowEnrichment(for: [row])
    }

    func enqueueChatListRowUpdate(_ row: ChatListRowFfi) {
        enqueueChatListRow(row)
    }

    func applyChatListUpdate(_ update: ChatListSubscriptionUpdateFfi) {
        switch update {
        case .row(_, let row):
            enqueueChatListRow(row)
        case .removeRow(_, let groupIdHex):
            removeChatListRow(groupIdHex: groupIdHex)
        case .snapshot(let trigger, let rows):
            if trigger == .pinOrderChanged, defersPinOrderSnapshots {
                deferredPinOrderSnapshot = rows
            } else {
                applyChatListSnapshot(rows, mergingPendingRows: false)
            }
        }
    }

    func beginPinOrderUITransition() -> UUID {
        let transitionID = UUID()
        defersPinOrderSnapshots = true
        deferredPinOrderSnapshot = nil
        pinOrderUITransitionID = transitionID
        return transitionID
    }

    /// Finishes the short host-side transition used while the system swipe
    /// drawer closes. A successful command supplies Marmot's authoritative
    /// order; an unsuccessful command falls back to any deferred snapshot.
    @discardableResult
    func finishPinOrderUITransition(
        transitionID: UUID,
        orderedGroupIds: [String]?
    ) -> Bool {
        guard pinOrderUITransitionID == transitionID else { return false }
        let snapshot = deferredPinOrderSnapshot
        defersPinOrderSnapshots = false
        deferredPinOrderSnapshot = nil
        pinOrderUITransitionID = nil

        if let orderedGroupIds {
            applyPinnedOrder(orderedGroupIds)
            return true
        }
        if let snapshot {
            applyChatListSnapshot(snapshot, mergingPendingRows: false)
            return true
        }
        return false
    }

    func removeChatListRow(groupIdHex: String) {
        pendingChatListRowsByGroupId[groupIdHex] = nil
        let hadPublishedRow = rowByGroupId[groupIdHex] != nil || itemByGroupId[groupIdHex] != nil
        rowByGroupId[groupIdHex] = nil
        itemByGroupId[groupIdHex] = nil
        avatarURLByGroupId[groupIdHex] = nil
        directPeerAccountIdByGroupId[groupIdHex] = nil
        inviterAccountIdByGroupId[groupIdHex] = nil
        inviterLookupCompletedGroupIds.remove(groupIdHex)
        inviterLookupFailureCountByGroupId[groupIdHex] = nil
        groupDetailsCache[groupIdHex] = nil
        directPeerLookupCompletedGroupIds.remove(groupIdHex)
        pendingDirectPeerRefreshGroupIds.remove(groupIdHex)
        if let currentAccount {
            draftStore.removeDraft(accountRef: currentAccount, groupIdHex: groupIdHex)
        }
        if hadPublishedRow {
            publishItems()
        }
    }

    func markGroupLeft(groupIdHex: String) {
        guard var row = rowByGroupId[groupIdHex] else { return }
        if let currentAccount {
            draftStore.removeDraft(accountRef: currentAccount, groupIdHex: groupIdHex)
        }
        row.leaveRequestPending = true
        row.leaveRequestedAtMs = row.leaveRequestedAtMs
            ?? UInt64(Date().timeIntervalSince1970 * 1_000)
        if storeRow(row) {
            publishItems()
        }
    }

    /// Reflect a locally-produced group change (e.g. an archive toggle) right
    /// away. Some local projection writes return group records rather than
    /// chat-list rows, so fold the changed fields into the current row.
    func applyLocalGroupChange(_ record: AppGroupRecordFfi) {
        pendingChatListRowsByGroupId[record.groupIdHex] = nil
        var row = rowByGroupId[record.groupIdHex] ?? Self.row(from: record)
        row.archived = record.archived
        row.pendingConfirmation = record.pendingConfirmation
        row.selfMembership = record.selfMembership
        row.leaveRequestPending = record.leaveRequestPending
        row.leaveRequestedAtMs = record.leaveRequestedAtMs
        row.groupName = record.name
        row.avatarUrl = record.avatarUrl
        if let name = ContentSanitizer.groupName(record.name) {
            row.title = name
        }
        avatarURLByGroupId[record.groupIdHex] = record.avatarUrl
        updateCachedGroupDetails(with: record)
        if storeRow(row) {
            publishItems()
        }
    }

    private func enqueueChatListRow(_ row: ChatListRowFfi) {
        pendingChatListRowsByGroupId[row.groupIdHex] = row
        guard pendingChatListUpdateTask == nil else { return }
        pendingChatListUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.chatListUpdateCoalescingDelayNanoseconds)
            guard !Task.isCancelled else { return }
            self?.flushPendingChatListUpdates()
        }
    }

    private func flushPendingChatListUpdates() {
        pendingChatListUpdateTask = nil
        let pendingRows = Array(pendingChatListRowsByGroupId.values)
        pendingChatListRowsByGroupId = [:]
        guard !pendingRows.isEmpty else { return }
        let timing = appState?.productAnalytics.beginTiming()
        defer { appState?.productAnalytics.recordTiming(.inboxBatch, since: timing) }

        var changed = false
        let muteLookup = currentMuteLookup()
        for row in pendingRows {
            changed = storeRow(row, muteLookup: muteLookup) || changed
        }
        if changed {
            publishItems()
        }
        scheduleRowEnrichment(for: pendingRows)
    }

    @discardableResult
    private func storeRow(_ row: ChatListRowFfi, muteLookup: MuteLookup? = nil) -> Bool {
        if row.conversationKind == .group {
            directPeerAccountIdByGroupId[row.groupIdHex] = nil
            directPeerLookupCompletedGroupIds.insert(row.groupIdHex)
        }
        if !row.pendingConfirmation {
            inviterAccountIdByGroupId[row.groupIdHex] = nil
            inviterLookupCompletedGroupIds.remove(row.groupIdHex)
            inviterLookupFailureCountByGroupId[row.groupIdHex] = nil
        }
        updateCachedGroupDetails(with: row)
        let item = makeItem(for: row, muteLookup: muteLookup)
        let changed = itemByGroupId[row.groupIdHex] != item
        rowByGroupId[row.groupIdHex] = row
        itemByGroupId[row.groupIdHex] = item
        return changed
    }

    func refreshDisplayProjections() {
        guard !rowByGroupId.isEmpty else { return }
        let timing = appState?.productAnalytics.beginTiming()
        defer { appState?.productAnalytics.recordTiming(.inboxRefresh, since: timing) }

        var changed = false
        let muteLookup = currentMuteLookup()
        for (groupId, row) in rowByGroupId {
            let item = makeItem(for: row, muteLookup: muteLookup)
            if itemByGroupId[groupId] != item {
                itemByGroupId[groupId] = item
                changed = true
            }
        }
        if changed {
            publishItems()
        }
    }

    /// Batch loops hoist one `MuteLookup` so the mute-store defaults read and
    /// the account scan run once per pass, not once per row.
    private struct MuteLookup {
        let accountIdHex: String?
        let mutedChatKeys: Set<String>
    }

    private func currentMuteLookup() -> MuteLookup {
        MuteLookup(accountIdHex: currentAccountIdHex, mutedChatKeys: ChatMuteStore.mutedChatKeys())
    }

    private func makeItem(for row: ChatListRowFfi, muteLookup: MuteLookup? = nil) -> Item {
        let display = display(for: row, details: groupDetailsCache[row.groupIdHex])
        let draftAccountRef = currentAccount ?? appState?.activeAccountRef
        let muteLookup = muteLookup ?? currentMuteLookup()
        return Item(
            row: row,
            avatarURL: display.avatarURL,
            avatarSeed: display.avatarSeed,
            title: display.title,
            isDirectMessage: display.isDirectMessage,
            directPeerAccountIdHex: display.directPeerAccountIdHex,
            inviterAccountIdHex: Self.inviterAccountIdHex(
                pendingConfirmation: row.pendingConfirmation,
                welcomerAccountIdHex: inviterAccountIdByGroupId[row.groupIdHex],
                directPeerAccountIdHex: display.directPeerAccountIdHex
                    ?? directPeerAccountIdByGroupId[row.groupIdHex]
            ),
            isMuted: muteLookup.accountIdHex.map {
                ChatMuteStore.isMuted(accountIdHex: $0, groupIdHex: row.groupIdHex, in: muteLookup.mutedChatKeys)
            } ?? false,
            leaveRequestPending: row.leaveRequestPending,
            draftSummary: draftAccountRef.flatMap {
                draftStore.summary(accountRef: $0, groupIdHex: row.groupIdHex)
            },
            mentionDisplayName: { [weak appState] entity in
                #if DEBUG
                if let name = self.mentionDisplayNameForTesting?(entity) {
                    return name
                }
                #endif
                return appState?.mentionDisplayName(for: entity)
            },
            systemEventNaming: GroupSystemEventNaming(
                currentAccountIdHex: muteLookup.accountIdHex,
                displayName: { [weak appState] accountIdHex in
                    appState?.displayName(forAccountIdHex: accountIdHex)
                        ?? IdentityFormatter.short(accountIdHex)
                }
            )
        )
    }

    /// The mute store keys by account id, while this model binds to the
    /// account label; resolve through the account summaries.
    private var currentAccountIdHex: String? {
        guard let appState,
              let accountRef = currentAccount ?? appState.activeAccountRef
        else { return nil }
        return appState.accounts.first { $0.label == accountRef }?.accountIdHex
    }

    private func updateCachedGroupDetails(with row: ChatListRowFfi) {
        guard var details = groupDetailsCache[row.groupIdHex] else { return }
        var group = details.group
        var changed = false
        // A live row is a projection, not authority: an absent name/avatar
        // means "not carried", not "cleared" — enrichment exists to backfill
        // exactly these fields. Clears arrive through the group-record path,
        // so only concrete row values are adopted here.
        if let rowName = ContentSanitizer.groupName(row.groupName), group.name != rowName {
            group.name = rowName
            changed = true
        }
        if let rowAvatarUrl = row.avatarUrl, group.avatarUrl != rowAvatarUrl {
            group.avatarUrl = rowAvatarUrl
            changed = true
        }
        guard changed else { return }
        details.group = group
        groupDetailsCache[row.groupIdHex] = details
        if let rowAvatarUrl = row.avatarUrl {
            avatarURLByGroupId[row.groupIdHex] = rowAvatarUrl
        }
    }

    private func updateCachedGroupDetails(with group: AppGroupRecordFfi) {
        guard var details = groupDetailsCache[group.groupIdHex] else { return }
        details.group = group
        groupDetailsCache[group.groupIdHex] = details
    }

    private func display(
        for row: ChatListRowFfi,
        details: GroupDetailsFfi?
    ) -> Display {
        let fallbackAvatarURL = ContentSanitizer.imageURL(row.avatarUrl ?? avatarURLByGroupId[row.groupIdHex])
        return Self.display(
            for: row,
            details: details,
            appState: appState,
            fallbackAvatarURL: fallbackAvatarURL,
            cachedDirectPeerAccountId: directPeerAccountIdByGroupId[row.groupIdHex]
                ?? appState.flatMap { appState in
                    guard let accountRef = appState.activeAccountRef else { return nil }
                    return appState.directChatPeerAccountId(
                        accountRef: accountRef,
                        groupIdHex: row.groupIdHex
                    )
                }
        )
    }

    struct Display {
        let title: String
        let avatarURL: URL?
        let avatarSeed: String
        let isDirectMessage: Bool?
        let directPeerAccountIdHex: String?
    }

    static func display(
        for row: ChatListRowFfi,
        details: GroupDetailsFfi?,
        appState: AppState?,
        fallbackAvatarURL: URL? = nil,
        cachedDirectPeerAccountId: String? = nil
    ) -> Display {
        if details == nil,
           let appState,
           row.conversationKind != .group,
           ContentSanitizer.groupName(row.groupName) == nil {
            if let cachedDirectPeerAccountId {
                return Display(
                    title: appState.knownDisplayName(forAccountIdHex: cachedDirectPeerAccountId)
                        ?? appState.shortNpub(forAccountIdHex: cachedDirectPeerAccountId),
                    avatarURL: appState.avatarURL(forAccountIdHex: cachedDirectPeerAccountId)
                        ?? fallbackAvatarURL,
                    avatarSeed: cachedDirectPeerAccountId,
                    isDirectMessage: true,
                    directPeerAccountIdHex: cachedDirectPeerAccountId
                )
            }
            // An unnamed MDK row's title is its MLS group id, not a user id.
            // Keep that internal hex out of the UI while roster enrichment is
            // still resolving the peer account.
            return Display(
                title: L10n.string("Direct message"),
                avatarURL: fallbackAvatarURL,
                avatarSeed: row.groupIdHex,
                isDirectMessage: true,
                directPeerAccountIdHex: nil
            )
        }
        guard let details, let appState else {
            return Display(
                title: Item.sanitizedTitle(for: row),
                avatarURL: fallbackAvatarURL,
                avatarSeed: row.groupIdHex,
                isDirectMessage: ContentSanitizer.groupName(row.groupName) == nil
                    ? nil
                    : false,
                directPeerAccountIdHex: nil
            )
        }

        let groupDisplay = Self.groupDisplay(for: details, appState: appState)
        let directPeerAccountIdHex = groupDisplay.isDirectMessage ? groupDisplay.otherMember : nil
        return Display(
            title: GroupDisplay.title(for: groupDisplay, appState: appState),
            avatarURL: GroupDisplay.avatarURL(for: groupDisplay, appState: appState) ?? fallbackAvatarURL,
            avatarSeed: GroupDisplay.avatarSeed(for: groupDisplay),
            isDirectMessage: groupDisplay.isDirectMessage,
            directPeerAccountIdHex: directPeerAccountIdHex
        )
    }

    static func nextLiveSubscriptionRetryDelay(after delay: UInt64) -> UInt64 {
        guard delay < liveSubscriptionMaximumRetryDelayNanoseconds else {
            return liveSubscriptionMaximumRetryDelayNanoseconds
        }
        let doubled = delay.multipliedReportingOverflow(by: 2)
        guard !doubled.overflow else { return liveSubscriptionMaximumRetryDelayNanoseconds }
        return min(doubled.partialValue, liveSubscriptionMaximumRetryDelayNanoseconds)
    }

    static func displayTitle(
        for row: ChatListRowFfi,
        details: GroupDetailsFfi?,
        appState: AppState?
    ) -> String {
        display(for: row, details: details, appState: appState).title
    }

    private static func groupDisplay(
        for details: GroupDetailsFfi,
        appState: AppState
    ) -> GroupDisplay.Resolved {
        let members = memberRecords(from: details)
        let otherMember = GroupDisplay.otherMemberAccount(
            in: members,
            myAccountId: appState.activeAccount?.accountIdHex
        )
        return GroupDisplay.resolve(
            group: details.group,
            otherMember: otherMember,
            memberCount: members.count
        )
    }

    static func memberRecords(from details: GroupDetailsFfi) -> [AppGroupMemberRecordFfi] {
        details.members.map {
            AppGroupMemberRecordFfi(
                memberIdHex: $0.memberIdHex,
                account: $0.account,
                local: $0.local
            )
        }
    }

    private static func rowNeedsDisplayEnrichment(_ row: ChatListRowFfi) -> Bool {
        ContentSanitizer.groupName(row.groupName) == nil
    }

    private func rowNeedsDirectPeerEnrichment(_ row: ChatListRowFfi) -> Bool {
        row.conversationKind != .group
            && Self.rowNeedsDisplayEnrichment(row)
            && directPeerAccountIdByGroupId[row.groupIdHex] == nil
            && !directPeerLookupCompletedGroupIds.contains(row.groupIdHex)
    }

    /// A known direct peer already names a two-member invite's inviter, so
    /// only invites without one need the welcomer read.
    private func rowNeedsInviterEnrichment(_ row: ChatListRowFfi) -> Bool {
        row.pendingConfirmation
            && inviterAccountIdByGroupId[row.groupIdHex] == nil
            && directPeerAccountIdByGroupId[row.groupIdHex] == nil
            && !inviterLookupCompletedGroupIds.contains(row.groupIdHex)
    }

    nonisolated static func inviterReadPlan(
        groupIds: [String],
        pendingInviteGroupIds: Set<String>,
        resolvedInviterGroupIds: Set<String>,
        completedLookupGroupIds: Set<String>,
        knownPeerGroupIds: Set<String>,
        limit: Int
    ) -> (read: [String], deferred: Set<String>) {
        let needsRead = groupIds.filter {
            pendingInviteGroupIds.contains($0)
                && !resolvedInviterGroupIds.contains($0)
                && !completedLookupGroupIds.contains($0)
                && !knownPeerGroupIds.contains($0)
        }
        let read = Array(needsRead.prefix(max(0, limit)))
        return (read: read, deferred: Set(needsRead.dropFirst(read.count)))
    }

    nonisolated static func shouldRetryInviterLookup(failureCount: Int) -> Bool {
        failureCount < inviterLookupFailureLimit
    }

    /// A pending invite's inviter: Marmot's welcomer once the group read has
    /// resolved it, else the direct peer, who is the only other member a DM
    /// invite can have come from. Nil once the invite has been answered.
    nonisolated static func inviterAccountIdHex(
        pendingConfirmation: Bool,
        welcomerAccountIdHex: String?,
        directPeerAccountIdHex: String?
    ) -> String? {
        guard pendingConfirmation else { return nil }
        return normalizedInviterAccountId(welcomerAccountIdHex)
            ?? normalizedInviterAccountId(directPeerAccountIdHex)
    }

    private nonisolated static func normalizedInviterAccountId(_ value: String?) -> String? {
        ConversationInvitePresentation.normalizedInviterAccountId(value)
    }

    nonisolated static func directPeerAccountId(
        memberIdsHex: [String],
        myAccountIdHex: String
    ) -> String? {
        let myAccountIdHex = myAccountIdHex.lowercased()
        let memberIds = Set(memberIdsHex.map { $0.lowercased() })
        guard memberIds.count == 2, memberIds.contains(myAccountIdHex) else { return nil }
        return memberIds.first { $0 != myAccountIdHex }
    }

    @discardableResult
    private func publishItems() -> Bool {
        let timing = appState?.productAnalytics.beginTiming()
        defer { appState?.productAnalytics.recordTiming(.inboxPublish, since: timing) }

        let signpost = Self.performanceSignposter.beginInterval("ChatsListViewModel.publishItems")
        defer { Self.performanceSignposter.endInterval("ChatsListViewModel.publishItems", signpost) }

        let all = Array(itemByGroupId.values)
        let nextItems = all.filter { !$0.row.archived }.sorted(by: Self.sortRule)
        let nextArchivedItems = all.filter { $0.row.archived }.sorted(by: Self.sortRule)
        guard items != nextItems || archivedItems != nextArchivedItems else { return false }
        items = nextItems
        archivedItems = nextArchivedItems
        visibleRowsRevision &+= 1
        #if DEBUG
        publishedItemsMutationCountForTesting += 1
        #endif
        updateActiveAccountUnreadSummary(rows: all.map(\.row))
        return true
    }

    private func updateActiveAccountUnreadSummary(rows: [ChatListRowFfi]) {
        guard
            let accountRef = currentAccount,
            let appState,
            let account = appState.accounts.first(where: { $0.label == accountRef })
        else { return }

        appState.updateAccountUnreadSummary(
            accountIdHex: account.accountIdHex,
            chatListRows: rows
        )
    }

    private func scheduleRowEnrichment(for rows: [ChatListRowFfi]) {
        guard let accountRef = currentAccount,
              let appState,
              let myAccountIdHex = appState.activeAccount?.accountIdHex
        else { return }
        let groupIds = rows.compactMap { row -> String? in
            guard rowNeedsDirectPeerEnrichment(row) || rowNeedsInviterEnrichment(row) else {
                return nil
            }
            return row.groupIdHex
        }
        guard !groupIds.isEmpty else { return }

        pendingDirectPeerRefreshGroupIds.formUnion(groupIds)
        guard avatarURLTask == nil else { return }
        let taskID = UUID()
        avatarEnrichmentTaskID = taskID
        avatarURLTask = Task { @MainActor [weak self, weak appState] in
            defer { self?.finishAvatarEnrichmentTask(taskID: taskID) }
            guard let self, let appState else { return }
            while !Task.isCancelled,
                  appState.canUseRuntimeForForegroundWork,
                  self.currentAccount == accountRef {
                let pendingGroupIds = self.pendingDirectPeerRefreshGroupIds
                self.pendingDirectPeerRefreshGroupIds = []
                let groupIds = Self.prioritizedEnrichmentGroupIds(
                    pendingGroupIds,
                    rowsByGroupId: self.rowByGroupId
                )
                guard !groupIds.isEmpty else { break }

                var changed = false
                var unresolvedGroupIds: Set<String> = []
                let muteLookup = self.currentMuteLookup()
                let membership: GroupMembershipPageLoadResult
                do {
                    let client = try appState.currentMarmotClient()
                    membership = try await GroupMembershipPageLoader.load(
                        groupIdsHex: groupIds,
                        pageRead: { groupIdsHex in
                            try await client.groupMemberIdsPage(
                                accountRef: accountRef,
                                groupIdsHex: groupIdsHex
                            )
                        },
                        fallbackRead: { groupIdHex in
                            try await client.groupMembers(
                                accountRef: accountRef,
                                groupIdHex: groupIdHex
                            ).map(\.memberIdHex)
                        }
                    )
                } catch is CancellationError {
                    return
                } catch {
                    unresolvedGroupIds.formUnion(groupIds)
                    membership = GroupMembershipPageLoadResult(
                        memberIdsByGroupId: [:],
                        adminIdsByGroupId: [:],
                        firstUnresolvedError: error,
                        pageReadCount: 0,
                        fallbackReadCount: 0
                    )
                }
                guard appState.canUseRuntimeForForegroundWork,
                      self.ownsAvatarEnrichmentTask(taskID: taskID, accountRef: accountRef)
                else { return }

                var peersByGroupId: [String: String] = [:]
                for groupId in groupIds {
                    guard let memberIds = membership.memberIdsByGroupId[groupId] else { continue }
                    if let other = Self.directPeerAccountId(
                        memberIdsHex: memberIds,
                        myAccountIdHex: myAccountIdHex
                    ) {
                        peersByGroupId[groupId] = other
                    }
                }

                // A two-member invite's peer is already its inviter.
                let invitePlan = Self.inviterReadPlan(
                    groupIds: groupIds,
                    pendingInviteGroupIds: Set(
                        groupIds.filter { self.rowByGroupId[$0]?.pendingConfirmation == true }
                    ),
                    resolvedInviterGroupIds: Set(self.inviterAccountIdByGroupId.keys),
                    completedLookupGroupIds: self.inviterLookupCompletedGroupIds,
                    knownPeerGroupIds: Set(peersByGroupId.keys),
                    limit: Self.inviterEnrichmentBatchLimit
                )
                var welcomersByGroupId: [String: String] = [:]
                var inviteGroupIdsToRetry = invitePlan.deferred
                unresolvedGroupIds.formUnion(invitePlan.deferred)
                for groupId in invitePlan.read {
                    do {
                        let client = try appState.currentMarmotClient()
                        let details = try await client.groupDetails(
                            accountRef: accountRef,
                            groupIdHex: groupId
                        )
                        if let welcomer = Self.normalizedInviterAccountId(
                            details.group.welcomerAccountIdHex
                        ) {
                            welcomersByGroupId[groupId] = welcomer
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        let failureCount =
                            (self.inviterLookupFailureCountByGroupId[groupId] ?? 0) + 1
                        self.inviterLookupFailureCountByGroupId[groupId] = failureCount
                        if Self.shouldRetryInviterLookup(failureCount: failureCount) {
                            inviteGroupIdsToRetry.insert(groupId)
                            unresolvedGroupIds.insert(groupId)
                        }
                    }
                }
                guard appState.canUseRuntimeForForegroundWork,
                      self.ownsAvatarEnrichmentTask(taskID: taskID, accountRef: accountRef)
                else { return }

                for groupId in groupIds {
                    guard let row = self.rowByGroupId[groupId] else { continue }
                    if membership.memberIdsByGroupId[groupId] != nil {
                        self.directPeerLookupCompletedGroupIds.insert(groupId)
                        if let other = peersByGroupId[groupId],
                           row.conversationKind != .group {
                            self.directPeerAccountIdByGroupId[groupId] = other
                            appState.warmProfileProjection(
                                forAccountIdHex: other,
                                refreshAfterLoad: true
                            )
                        }
                    } else if self.rowNeedsDirectPeerEnrichment(row) {
                        unresolvedGroupIds.insert(groupId)
                    }
                    if row.pendingConfirmation, !inviteGroupIdsToRetry.contains(groupId) {
                        self.inviterLookupCompletedGroupIds.insert(groupId)
                        // `storeRow` clears the peer cache for group rows, so the
                        // resolved inviter has to live in this store to survive.
                        if let inviter = Self.inviterAccountIdHex(
                            pendingConfirmation: true,
                            welcomerAccountIdHex: welcomersByGroupId[groupId],
                            directPeerAccountIdHex: peersByGroupId[groupId]
                        ) {
                            self.inviterAccountIdByGroupId[groupId] = inviter
                            appState.warmProfileProjection(
                                forAccountIdHex: inviter,
                                refreshAfterLoad: true
                            )
                        }
                    }
                    let item = self.makeItem(for: row, muteLookup: muteLookup)
                    if self.itemByGroupId[groupId] != item {
                        self.itemByGroupId[groupId] = item
                        changed = true
                    }
                }
                guard !Task.isCancelled,
                      appState.canUseRuntimeForForegroundWork,
                      self.ownsAvatarEnrichmentTask(taskID: taskID, accountRef: accountRef)
                else { break }
                self.pendingDirectPeerRefreshGroupIds.formUnion(
                    unresolvedGroupIds.filter { self.rowByGroupId[$0] != nil }
                )
                if changed {
                    self.publishItems()
                }
                if !unresolvedGroupIds.isEmpty {
                    do {
                        try await Task.sleep(nanoseconds: Self.rowEnrichmentRetryDelayNanoseconds)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    private func ownsChatListTask(taskID: UUID, accountRef: String) -> Bool {
        currentAccount == accountRef && chatListTaskID == taskID
    }

    private func finishChatListTask(taskID: UUID) {
        guard chatListTaskID == taskID else { return }
        chatListTask = nil
        chatListTaskID = nil
    }

    private func ownsAvatarEnrichmentTask(taskID: UUID, accountRef: String) -> Bool {
        currentAccount == accountRef && avatarEnrichmentTaskID == taskID
    }

    private func finishAvatarEnrichmentTask(taskID: UUID) {
        guard avatarEnrichmentTaskID == taskID else { return }
        avatarURLTask = nil
        avatarEnrichmentTaskID = nil
    }

    /// Resolve the rows a user is most likely to see first. The previous set
    /// conversion made enrichment order arbitrary, so an off-screen old chat
    /// could delay a visible DM even though every read was local.
    static func prioritizedEnrichmentGroupIds(
        _ groupIds: Set<String>,
        rowsByGroupId: [String: ChatListRowFfi]
    ) -> [String] {
        groupIds.sorted { lhs, rhs in
            guard let lhsRow = rowsByGroupId[lhs] else { return false }
            guard let rhsRow = rowsByGroupId[rhs] else { return true }
            if lhsRow.pinned != rhsRow.pinned {
                return lhsRow.pinned
            }
            if lhsRow.pinned {
                let lhsPosition = lhsRow.pinnedPosition ?? UInt32.max
                let rhsPosition = rhsRow.pinnedPosition ?? UInt32.max
                if lhsPosition != rhsPosition {
                    return lhsPosition < rhsPosition
                }
            }
            if lhsRow.activitySortAt != rhsRow.activitySortAt {
                return lhsRow.activitySortAt > rhsRow.activitySortAt
            }
            return lhs < rhs
        }
    }

    #if DEBUG
    func groupDetailsCacheEntryForTesting(groupIdHex: String) -> GroupDetailsFfi? {
        groupDetailsCache[groupIdHex]
    }

    func seedGroupDetailsCacheForTesting(_ details: GroupDetailsFfi) {
        let groupId = details.group.groupIdHex
        groupDetailsCache[groupId] = details
        directPeerLookupCompletedGroupIds.insert(groupId)
        if let avatarUrl = details.group.avatarUrl {
            avatarURLByGroupId[groupId] = avatarUrl
        }
        if let row = rowByGroupId[groupId] {
            let item = makeItem(for: row)
            if itemByGroupId[groupId] != item {
                itemByGroupId[groupId] = item
                publishItems()
            }
        }
    }

    func setLoadErrorForTesting(_ error: String?) {
        loadError = error
    }

    var avatarEnrichmentTaskIDForTesting: UUID? { avatarEnrichmentTaskID }

    func installAvatarEnrichmentTaskForTesting(taskID: UUID) {
        avatarURLTask?.cancel()
        avatarURLTask = Task {}
        avatarEnrichmentTaskID = taskID
    }

    func finishAvatarEnrichmentTaskForTesting(taskID: UUID) {
        finishAvatarEnrichmentTask(taskID: taskID)
    }
    #endif

    /// Match Marmot's durable chat-list ordering: manually ordered pinned rows
    /// first, then activity order. `activitySortAt` survives secure pruning
    /// even when a row no longer has a last-message preview.
    private static let sortRule: (Item, Item) -> Bool = { a, b in
        if a.row.pinned != b.row.pinned {
            return a.row.pinned
        }
        if a.row.pinned {
            let aPosition = a.row.pinnedPosition ?? UInt32.max
            let bPosition = b.row.pinnedPosition ?? UInt32.max
            if aPosition != bPosition {
                return aPosition < bPosition
            }
        }
        if a.row.activitySortAt != b.row.activitySortAt {
            return a.row.activitySortAt > b.row.activitySortAt
        }
        return a.id < b.id
    }

    private static func row(from group: AppGroupRecordFfi) -> ChatListRowFfi {
        let title = ContentSanitizer.groupName(group.name) ?? IdentityFormatter.short(group.groupIdHex)
        let now = UInt64(Date().timeIntervalSince1970)
        return ChatListRowFfi(
            groupIdHex: group.groupIdHex,
            pinned: false,
            pinnedPosition: nil,
            archived: group.archived,
            pendingConfirmation: group.pendingConfirmation,
            lifecycleState: group.disbanded ? .disbanded : .stable,
            disbanding: group.disbanding,
            disbandRequest: group.disbandRequest,
            title: title,
            groupName: group.name,
            avatarUrl: group.avatarUrl,
            avatar: nil,
            lastMessage: nil,
            unreadCount: 0,
            hasUnread: false,
            manuallyMarkedUnread: false,
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            conversationCreatedAt: now,
            activitySortAt: now,
            updatedAt: now,
            selfMembership: group.selfMembership,
            conversationKind: .group,
            muted: false,
            mutedUntilMs: nil,
            leaveRequestPending: group.leaveRequestPending,
            leaveRequestedAtMs: group.leaveRequestedAtMs
        )
    }
}

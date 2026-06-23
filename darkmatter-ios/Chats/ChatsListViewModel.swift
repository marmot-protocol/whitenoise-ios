import Foundation
import Observation
import MarmotKit

/// Owns the live list of chats for the currently active account. The list is
/// now driven by Marmot's durable chat-list projection instead of rebuilding
/// previews from account-wide message snapshots on every appearance.
@Observable
@MainActor
final class ChatsListViewModel {

    struct Item: Identifiable {
        let row: ChatListRowFfi
        let avatarURL: URL?
        let title: String
        let previewText: String?
        let searchHaystack: String

        init(
            row: ChatListRowFfi,
            avatarURL: URL?,
            title: String,
            mentionDisplayName: MarkdownMentionResolver? = nil
        ) {
            let previewText = Self.sanitizedPreview(
                from: row.lastMessage,
                mentionDisplayName: mentionDisplayName
            )
            self.row = row
            self.avatarURL = avatarURL
            self.title = title
            self.previewText = previewText
            self.searchHaystack = Self.makeSearchHaystack(
                title: title,
                previewText: previewText
            )
        }

        var id: String { row.groupIdHex }
        var unreadCount: UInt64 { row.unreadCount }
        var hasUnread: Bool { row.hasUnread }
        var isArchived: Bool { row.archived }
        var firstUnreadMessageIdHex: String? { row.firstUnreadMessageIdHex }
        var lastMessage: ChatListMessagePreviewFfi? { row.lastMessage }
        var projectedGroup: AppGroupRecordFfi {
            AppGroupRecordFfi(
                groupIdHex: row.groupIdHex,
                endpoint: "",
                name: ProfileSanitizer.groupName(row.groupName) ?? title,
                description: "",
                admins: [],
                relays: [],
                nostrGroupIdHex: "",
                avatarUrl: row.avatarUrl,
                avatarDim: nil,
                avatarThumbhash: nil,
                encryptedMedia: AppGroupEncryptedMediaComponentFfi(
                    componentId: 0,
                    component: "",
                    required: false,
                    mediaFormat: "",
                    allowedLocatorKinds: [],
                    defaultBlobEndpoints: []
                ),
                archived: row.archived,
                pendingConfirmation: row.pendingConfirmation,
                welcomerAccountIdHex: nil,
                viaWelcomeMessageIdHex: nil
            )
        }

        static func sanitizedTitle(for row: ChatListRowFfi) -> String {
            if let name = ProfileSanitizer.groupName(row.groupName) { return name }
            if let name = ProfileSanitizer.groupName(row.title) { return name }
            return IdentityFormatter.short(row.groupIdHex)
        }

        private static func sanitizedPreview(
            from preview: ChatListMessagePreviewFfi?,
            mentionDisplayName: MarkdownMentionResolver?
        ) -> String? {
            preview.flatMap {
                ProfileSanitizer.singleLine(
                    MessagePreview.body($0, mentionDisplayName: mentionDisplayName),
                    maxLength: 140
                )
            }
        }

        private static func makeSearchHaystack(title: String, previewText: String?) -> String {
            (title + " " + (previewText ?? "")).localizedLowercase
        }
    }

    private(set) var items: [Item] = []
    private(set) var archivedItems: [Item] = []
    private(set) var isLoading: Bool = false
    private(set) var loadError: String?

    private weak var appState: AppState?
    private var chatListTask: Task<Void, Never>?
    private var avatarURLTask: Task<Void, Never>?
    private var pendingChatListUpdateTask: Task<Void, Never>?
    private var currentAccount: String?
    private var rowByGroupId: [String: ChatListRowFfi] = [:]
    private var itemByGroupId: [String: Item] = [:]
    private var pendingChatListRowsByGroupId: [String: ChatListRowFfi] = [:]
    private var avatarURLByGroupId: [String: String] = [:]
    private var avatarURLLoadedGroupIds: Set<String> = []
    private var pendingAvatarURLRefreshGroupIds: Set<String> = []
    private var groupDetailsCache: [String: GroupDetailsFfi] = [:]
    private var groupDetailsLoadedGroupIds: Set<String> = []
    private var pendingGroupDetailsRefreshGroupIds: Set<String> = []

    private static let chatListUpdateCoalescingDelayNanoseconds: UInt64 = 16_000_000

    init(appState: AppState) {
        self.appState = appState
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
        avatarURLTask?.cancel()
        avatarURLTask = nil
        pendingChatListUpdateTask?.cancel()
        pendingChatListUpdateTask = nil
        if currentAccount != accountRef {
            rowByGroupId = [:]
            itemByGroupId = [:]
            items = []
            archivedItems = []
            pendingChatListRowsByGroupId = [:]
            avatarURLByGroupId = [:]
            avatarURLLoadedGroupIds = []
            pendingAvatarURLRefreshGroupIds = []
            groupDetailsCache = [:]
            groupDetailsLoadedGroupIds = []
            pendingGroupDetailsRefreshGroupIds = []
        }
        loadError = nil

        guard let accountRef else {
            currentAccount = nil
            return
        }
        guard let appState, appState.canUseRuntimeForForegroundWork else { return }
        currentAccount = accountRef
        isLoading = true
        defer {
            if currentAccount == accountRef {
                isLoading = false
            }
        }
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
            guard currentAccount == accountRef else { return }
            loadError = error.localizedDescription
        }
        guard currentAccount == accountRef else { return }
        startLiveUpdates(accountRef: accountRef)
    }

    private func startLiveUpdates(accountRef: String) {
        guard let appState else { return }
        chatListTask = Task { [weak self, weak appState] in
            do {
                guard let appState, appState.canUseRuntimeForForegroundWork else { return }
                let client = try appState.currentMarmotClient()
                let chatListSub = try await client.marmot.subscribeChatList(
                    accountRef: accountRef,
                    includeArchived: true
                )
                guard !Task.isCancelled else { return }
                let snapshot = await client.chatListSubscriptionSnapshot(chatListSub)
                guard !Task.isCancelled else { return }
                self?.applyChatListSnapshot(snapshot)

                for await update in SubscriptionDriver.chatListUpdates(chatListSub) {
                    self?.applyChatListUpdate(update)
                }
            } catch {
                guard !Task.isCancelled else { return }
                if self?.rowByGroupId.isEmpty == true {
                    self?.loadError = error.localizedDescription
                }
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

    /// O(1) lookup for a chat-list item by its group id, backed by the
    /// id-keyed `itemByGroupId` map. Views that resolve a single row by id
    /// (e.g. deep-link destinations) should use this instead of scanning the
    /// published `items`/`archivedItems` arrays in `body`.
    func item(groupIdHex: String) -> Item? {
        itemByGroupId[groupIdHex]
    }

    func applyChatListSnapshot(_ snapshot: [ChatListRowFfi]) {
        pendingChatListRowsByGroupId = [:]
        rowByGroupId = [:]
        itemByGroupId = [:]
        for row in snapshot {
            storeRow(row)
        }
        pruneEnrichmentCaches(toSurviving: Set(rowByGroupId.keys))
        publishItems()
        scheduleRowEnrichment(for: snapshot)
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
        groupDetailsLoadedGroupIds = Self.intersecting(groupDetailsLoadedGroupIds, with: surviving)
        avatarURLLoadedGroupIds = Self.intersecting(avatarURLLoadedGroupIds, with: surviving)
        pendingAvatarURLRefreshGroupIds = Self.intersecting(pendingAvatarURLRefreshGroupIds, with: surviving)
        pendingGroupDetailsRefreshGroupIds = Self.intersecting(pendingGroupDetailsRefreshGroupIds, with: surviving)
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
        storeRow(row)
        publishItems()
        scheduleRowEnrichment(for: [row])
    }

    func applyChatListUpdate(_ update: ChatListSubscriptionUpdateFfi) {
        switch update {
        case .row(_, let row):
            enqueueChatListRow(row)
        case .removeRow(_, let groupIdHex):
            removeChatListRow(groupIdHex: groupIdHex)
        }
    }

    func removeChatListRow(groupIdHex: String) {
        pendingChatListRowsByGroupId[groupIdHex] = nil
        rowByGroupId[groupIdHex] = nil
        itemByGroupId[groupIdHex] = nil
        avatarURLByGroupId[groupIdHex] = nil
        avatarURLLoadedGroupIds.remove(groupIdHex)
        pendingAvatarURLRefreshGroupIds.remove(groupIdHex)
        groupDetailsCache[groupIdHex] = nil
        groupDetailsLoadedGroupIds.remove(groupIdHex)
        pendingGroupDetailsRefreshGroupIds.remove(groupIdHex)
        publishItems()
    }

    /// Reflect a locally-produced group change (e.g. an archive toggle) right
    /// away. Some local projection writes return group records rather than
    /// chat-list rows, so fold the changed fields into the current row.
    func applyLocalGroupChange(_ record: AppGroupRecordFfi) {
        pendingChatListRowsByGroupId[record.groupIdHex] = nil
        var row = rowByGroupId[record.groupIdHex] ?? Self.row(from: record)
        row.archived = record.archived
        row.pendingConfirmation = record.pendingConfirmation
        row.groupName = record.name
        row.avatarUrl = record.avatarUrl
        if let name = ProfileSanitizer.groupName(record.name) {
            row.title = name
        }
        avatarURLByGroupId[record.groupIdHex] = record.avatarUrl
        avatarURLLoadedGroupIds.insert(record.groupIdHex)
        pendingAvatarURLRefreshGroupIds.remove(record.groupIdHex)
        storeRow(row)
        publishItems()
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
        for row in pendingRows {
            storeRow(row)
        }
        publishItems()
        scheduleRowEnrichment(for: pendingRows)
    }

    private func storeRow(_ row: ChatListRowFfi) {
        rowByGroupId[row.groupIdHex] = row
        itemByGroupId[row.groupIdHex] = makeItem(for: row)
    }

    func refreshDisplayProjections() {
        guard !groupDetailsCache.isEmpty else { return }
        var changed = false
        for groupId in groupDetailsCache.keys {
            guard let row = rowByGroupId[groupId] else { continue }
            itemByGroupId[groupId] = makeItem(for: row)
            changed = true
        }
        if changed {
            publishItems()
        }
    }

    private func makeItem(for row: ChatListRowFfi) -> Item {
        let details = groupDetailsCache[row.groupIdHex]
        return Item(
            row: row,
            avatarURL: displayAvatarURL(for: row, details: details),
            title: Self.displayTitle(for: row, details: details, appState: appState),
            mentionDisplayName: { [weak appState] entity in
                appState?.mentionDisplayName(for: entity)
            }
        )
    }

    private func displayAvatarURL(for row: ChatListRowFfi, details: GroupDetailsFfi?) -> URL? {
        if let details, let appState {
            let members = Self.memberRecords(from: details)
            let otherMember = GroupDisplay.otherMemberAccount(
                in: members,
                myAccountId: appState.activeAccount?.accountIdHex
            )
            if let url = GroupDisplay.avatarURL(
                group: details.group,
                otherMember: otherMember,
                memberCount: members.count,
                appState: appState
            ) {
                return url
            }
        }
        return ProfileSanitizer.imageURL(row.avatarUrl ?? avatarURLByGroupId[row.groupIdHex])
    }

    static func displayTitle(
        for row: ChatListRowFfi,
        details: GroupDetailsFfi?,
        appState: AppState?
    ) -> String {
        if let details, let appState {
            let members = memberRecords(from: details)
            let otherMember = GroupDisplay.otherMemberAccount(
                in: members,
                myAccountId: appState.activeAccount?.accountIdHex
            )
            return GroupDisplay.title(
                group: details.group,
                otherMember: otherMember,
                memberCount: members.count,
                appState: appState
            )
        }
        return Item.sanitizedTitle(for: row)
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
        ProfileSanitizer.groupName(row.groupName) == nil
    }

    private func publishItems() {
        let all = Array(itemByGroupId.values)
        items = all.filter { !$0.row.archived }.sorted(by: Self.sortRule)
        archivedItems = all.filter { $0.row.archived }.sorted(by: Self.sortRule)
        updateActiveAccountUnreadSummary(rows: all.map(\.row))
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
        guard let accountRef = currentAccount, let appState else { return }
        let groupIds = rows.compactMap { row -> String? in
            let needsAvatar = row.avatarUrl == nil && !avatarURLLoadedGroupIds.contains(row.groupIdHex)
            let needsDisplay = Self.rowNeedsDisplayEnrichment(row)
                && !groupDetailsLoadedGroupIds.contains(row.groupIdHex)
            guard needsAvatar || needsDisplay else { return nil }
            return row.groupIdHex
        }
        guard !groupIds.isEmpty else { return }

        pendingAvatarURLRefreshGroupIds.formUnion(
            groupIds.filter { groupId in
                rowByGroupId[groupId]?.avatarUrl == nil
                    && !avatarURLLoadedGroupIds.contains(groupId)
            }
        )
        pendingGroupDetailsRefreshGroupIds.formUnion(
            groupIds.filter { groupId in
                guard let row = rowByGroupId[groupId] else { return false }
                return Self.rowNeedsDisplayEnrichment(row)
                    && !groupDetailsLoadedGroupIds.contains(groupId)
            }
        )
        guard avatarURLTask == nil else { return }
        avatarURLTask = Task { @MainActor [weak self, weak appState] in
            guard let self, let appState else { return }
            while !Task.isCancelled, self.currentAccount == accountRef {
                let avatarGroupIds = Array(self.pendingAvatarURLRefreshGroupIds)
                let displayGroupIds = Array(self.pendingGroupDetailsRefreshGroupIds)
                self.pendingAvatarURLRefreshGroupIds = []
                self.pendingGroupDetailsRefreshGroupIds = []
                let groupIds = Array(Set(avatarGroupIds + displayGroupIds))
                guard !groupIds.isEmpty else { break }

                var changed = false
                for groupId in groupIds where !Task.isCancelled {
                    guard let details = try? await appState.marmot.groupDetails(
                        accountRef: accountRef,
                        groupIdHex: groupId
                    ) else { continue }

                    // `groupDetails` is a suspension point: a full-snapshot
                    // replace (`applyChatListSnapshot`) can run during the await
                    // and prune this group out of `rowByGroupId` and the
                    // enrichment caches. Skip writing any cache/loaded-set state
                    // for a group that no longer survives so in-flight
                    // enrichment cannot strand entries for a removed row.
                    guard let row = self.rowByGroupId[groupId] else { continue }

                    self.groupDetailsCache[groupId] = details
                    self.groupDetailsLoadedGroupIds.insert(groupId)
                    if Self.rowNeedsDisplayEnrichment(row) {
                        let members = Self.memberRecords(from: details)
                        if members.count == 2,
                           let other = GroupDisplay.otherMemberAccount(
                               in: members,
                               myAccountId: appState.activeAccount?.accountIdHex
                           ) {
                            appState.warmProfileProjection(
                                forAccountIdHex: other,
                                refreshAfterLoad: true
                            )
                        }
                    }

                    if row.avatarUrl == nil {
                        self.avatarURLLoadedGroupIds.insert(groupId)
                        if let avatarUrl = details.group.avatarUrl {
                            self.avatarURLByGroupId[groupId] = avatarUrl
                        }
                    }

                    self.itemByGroupId[groupId] = self.makeItem(for: row)
                    changed = true
                }
                guard !Task.isCancelled, self.currentAccount == accountRef else { break }
                if changed {
                    self.publishItems()
                }
            }
            if self.currentAccount == accountRef {
                self.avatarURLTask = nil
            }
        }
    }

    /// Newest projected activity first; rows without messages fall back to the
    /// projection update time, then title.
    private static let sortRule: (Item, Item) -> Bool = { a, b in
        switch (a.row.lastMessage?.timelineAt, b.row.lastMessage?.timelineAt) {
        case let (ta?, tb?) where ta != tb:
            return ta > tb
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            if a.row.updatedAt != b.row.updatedAt {
                return a.row.updatedAt > b.row.updatedAt
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    private static func row(from group: AppGroupRecordFfi) -> ChatListRowFfi {
        let title = ProfileSanitizer.groupName(group.name) ?? IdentityFormatter.short(group.groupIdHex)
        return ChatListRowFfi(
            groupIdHex: group.groupIdHex,
            archived: group.archived,
            pendingConfirmation: group.pendingConfirmation,
            title: title,
            groupName: group.name,
            avatarUrl: group.avatarUrl,
            avatar: nil,
            lastMessage: nil,
            unreadCount: 0,
            hasUnread: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            updatedAt: UInt64(Date().timeIntervalSince1970)
        )
    }
}

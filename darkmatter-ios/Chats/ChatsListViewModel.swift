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
            mentionDisplayName: MarkdownMentionResolver? = nil
        ) {
            let title = Self.sanitizedTitle(for: row)
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

        private static func sanitizedTitle(for row: ChatListRowFfi) -> String {
            ProfileSanitizer.groupName(row.title) ?? IdentityFormatter.short(row.groupIdHex)
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
        }
        loadError = nil
        currentAccount = accountRef

        guard let accountRef, let appState else { return }
        isLoading = true
        do {
            applyChatListSnapshot(try appState.marmot.chatList(accountRef: accountRef, includeArchived: true))
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
        startLiveUpdates(accountRef: accountRef)
    }

    private func startLiveUpdates(accountRef: String) {
        guard let appState else { return }
        chatListTask = Task { [weak self, weak appState] in
            do {
                guard let appState else { return }
                let chatListSub = try await appState.marmot.subscribeChatList(
                    accountRef: accountRef,
                    includeArchived: true
                )
                guard !Task.isCancelled else { return }
                let snapshot = await appState.marmot.chatListSubscriptionSnapshot(chatListSub)
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
        guard let accountRef = currentAccount, let appState else { return }
        do {
            applyChatListSnapshot(try appState.marmot.chatList(accountRef: accountRef, includeArchived: true))
        } catch {
            // Non-fatal: subscription updates remain authoritative.
        }
    }

    func applyChatListSnapshot(_ snapshot: [ChatListRowFfi]) {
        pendingChatListRowsByGroupId = [:]
        rowByGroupId = [:]
        itemByGroupId = [:]
        for row in snapshot {
            storeRow(row)
        }
        publishItems()
        scheduleAvatarURLRefresh(for: snapshot)
    }

    func applyChatListRow(_ row: ChatListRowFfi) {
        pendingChatListRowsByGroupId[row.groupIdHex] = nil
        storeRow(row)
        publishItems()
        scheduleAvatarURLRefresh(for: [row])
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
        scheduleAvatarURLRefresh(for: pendingRows)
    }

    private func storeRow(_ row: ChatListRowFfi) {
        rowByGroupId[row.groupIdHex] = row
        itemByGroupId[row.groupIdHex] = makeItem(for: row)
    }

    private func makeItem(for row: ChatListRowFfi) -> Item {
        Item(
            row: row,
            avatarURL: ProfileSanitizer.imageURL(row.avatarUrl ?? avatarURLByGroupId[row.groupIdHex]),
            mentionDisplayName: { [weak appState] entity in
                appState?.mentionDisplayName(for: entity)
            }
        )
    }

    private func publishItems() {
        let all = Array(itemByGroupId.values)
        items = all.filter { !$0.row.archived }.sorted(by: Self.sortRule)
        archivedItems = all.filter { $0.row.archived }.sorted(by: Self.sortRule)
    }

    private func scheduleAvatarURLRefresh(for rows: [ChatListRowFfi]) {
        guard let accountRef = currentAccount, let appState else { return }
        let groupIds = rows
            .filter { $0.avatarUrl == nil }
            .map(\.groupIdHex)
            .filter { !avatarURLLoadedGroupIds.contains($0) }
        guard !groupIds.isEmpty else { return }

        pendingAvatarURLRefreshGroupIds.formUnion(groupIds)
        guard avatarURLTask == nil else { return }
        avatarURLTask = Task { @MainActor [weak self, weak appState] in
            guard let self, let appState else { return }
            while !Task.isCancelled, self.currentAccount == accountRef {
                let groupIds = Array(self.pendingAvatarURLRefreshGroupIds)
                self.pendingAvatarURLRefreshGroupIds = []
                guard !groupIds.isEmpty else { break }

                var loaded = Set<String>()
                var updates: [String: String] = [:]
                for groupId in groupIds where !Task.isCancelled {
                    if let details = try? await appState.marmot.groupDetails(
                        accountRef: accountRef,
                        groupIdHex: groupId
                    ) {
                        loaded.insert(groupId)
                        if let avatarUrl = details.group.avatarUrl {
                            updates[groupId] = avatarUrl
                        }
                    }
                }
                guard !Task.isCancelled, self.currentAccount == accountRef else { break }
                self.avatarURLLoadedGroupIds.formUnion(loaded)
                var changed = false
                for (groupId, avatarURL) in updates {
                    self.avatarURLByGroupId[groupId] = avatarURL
                    if let row = self.rowByGroupId[groupId] {
                        self.itemByGroupId[groupId] = self.makeItem(for: row)
                        changed = true
                    }
                }
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

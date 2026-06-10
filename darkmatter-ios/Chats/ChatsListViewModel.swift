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
        var mentionDisplayName: MarkdownMentionResolver?
        var id: String { row.groupIdHex }
        var title: String { ProfileSanitizer.groupName(row.title) ?? IdentityFormatter.short(row.groupIdHex) }
        @MainActor var previewText: String? {
            row.lastMessage.flatMap { preview in
                ProfileSanitizer.singleLine(
                    MessagePreview.body(preview, mentionDisplayName: mentionDisplayName),
                    maxLength: 140
                )
            }
        }
        var unreadCount: UInt64 { row.unreadCount }
        var hasUnread: Bool { row.hasUnread }
        var isArchived: Bool { row.archived }
        var firstUnreadMessageIdHex: String? { row.firstUnreadMessageIdHex }
        var lastMessage: ChatListMessagePreviewFfi? { row.lastMessage }
    }

    private(set) var items: [Item] = []
    private(set) var archivedItems: [Item] = []
    private(set) var isLoading: Bool = false
    private(set) var loadError: String?

    private weak var appState: AppState?
    private var chatListTask: Task<Void, Never>?
    private var avatarURLTask: Task<Void, Never>?
    private var currentAccount: String?
    private var rows: [ChatListRowFfi] = []
    private var avatarURLByGroupId: [String: String] = [:]
    private var avatarURLLoadedGroupIds: Set<String> = []

    init(appState: AppState) {
        self.appState = appState
    }

    isolated deinit {
        chatListTask?.cancel()
        avatarURLTask?.cancel()
    }

    /// Begin (or rebind, when `accountRef` changes) the projected chat-list
    /// subscription.
    func bind(accountRef: String?, force: Bool = false) async {
        if currentAccount == accountRef, !force { return }
        chatListTask?.cancel()
        chatListTask = nil
        avatarURLTask?.cancel()
        avatarURLTask = nil
        if currentAccount != accountRef {
            rows = []
            items = []
            archivedItems = []
            avatarURLByGroupId = [:]
            avatarURLLoadedGroupIds = []
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
                self?.applyChatListSnapshot(chatListSub.snapshot())

                for await update in SubscriptionDriver.chatListUpdates(chatListSub) {
                    self?.applyChatListUpdate(update)
                }
            } catch {
                guard !Task.isCancelled else { return }
                if self?.rows.isEmpty == true {
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
        rows = snapshot
        recompute()
        scheduleAvatarURLRefresh()
    }

    func applyChatListRow(_ row: ChatListRowFfi) {
        if let index = rows.firstIndex(where: { $0.groupIdHex == row.groupIdHex }) {
            rows[index] = row
        } else {
            rows.append(row)
        }
        recompute()
        scheduleAvatarURLRefresh()
    }

    func applyChatListUpdate(_ update: ChatListSubscriptionUpdateFfi) {
        switch update {
        case .row(_, let row):
            applyChatListRow(row)
        case .removeRow(_, let groupIdHex):
            removeChatListRow(groupIdHex: groupIdHex)
        }
    }

    func removeChatListRow(groupIdHex: String) {
        rows.removeAll { $0.groupIdHex == groupIdHex }
        recompute()
    }

    /// Reflect a locally-produced group change (e.g. an archive toggle) right
    /// away. Some local projection writes return group records rather than
    /// chat-list rows, so fold the changed fields into the current row.
    func applyLocalGroupChange(_ record: AppGroupRecordFfi) {
        if let index = rows.firstIndex(where: { $0.groupIdHex == record.groupIdHex }) {
            var row = rows[index]
            row.archived = record.archived
            row.pendingConfirmation = record.pendingConfirmation
            row.groupName = record.name
            row.avatarUrl = record.avatarUrl
            if let name = ProfileSanitizer.groupName(record.name) {
                row.title = name
            }
            rows[index] = row
        } else {
            rows.append(Self.row(from: record))
        }
        avatarURLByGroupId[record.groupIdHex] = record.avatarUrl
        avatarURLLoadedGroupIds.insert(record.groupIdHex)
        recompute()
    }

    private func recompute() {
        let all = rows.map { row in
            Item(
                row: row,
                avatarURL: ProfileSanitizer.imageURL(row.avatarUrl ?? avatarURLByGroupId[row.groupIdHex]),
                mentionDisplayName: { [weak appState] entity in
                    appState?.mentionDisplayName(for: entity)
                }
            )
        }
        items = all.filter { !$0.row.archived }.sorted(by: Self.sortRule)
        archivedItems = all.filter { $0.row.archived }.sorted(by: Self.sortRule)
    }

    private func scheduleAvatarURLRefresh() {
        guard let accountRef = currentAccount, let appState else { return }
        let groupIds = rows
            .filter { $0.avatarUrl == nil }
            .map(\.groupIdHex)
            .filter { !avatarURLLoadedGroupIds.contains($0) }
        guard !groupIds.isEmpty else { return }

        avatarURLTask?.cancel()
        avatarURLTask = Task { [weak self, weak appState] in
            guard let self, let appState else { return }
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
            guard !Task.isCancelled, !loaded.isEmpty else { return }
            self.avatarURLLoadedGroupIds.formUnion(loaded)
            for (groupId, avatarURL) in updates {
                self.avatarURLByGroupId[groupId] = avatarURL
            }
            self.recompute()
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

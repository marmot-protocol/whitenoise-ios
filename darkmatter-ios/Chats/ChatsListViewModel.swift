import Foundation
import Observation
import MarmotKit

/// Owns the live list of chats for the currently active account. Combines
/// three sources per row: the group record (`subscribeChats`), the latest
/// message for the preview + ordering (account-wide `messages` query, kept
/// fresh by an account-wide messages subscription), and the member roster
/// (so a 2-member group with no name can render as the other person).
@Observable
final class ChatsListViewModel {

    struct Item: Identifiable {
        let group: AppGroupRecordFfi
        let latest: AppMessageRecordFfi?
        /// Non-self member's account id — used to title/avatar a 2-member,
        /// unnamed group as the other person.
        let otherMemberAccount: String?
        let memberCount: Int
        var id: String { group.groupIdHex }
    }

    private(set) var items: [Item] = []
    private(set) var archivedItems: [Item] = []
    private(set) var isLoading: Bool = false
    private(set) var loadError: String?

    private weak var appState: AppState?
    private var chatsTask: Task<Void, Never>?
    private var messagesTask: Task<Void, Never>?
    private var currentAccount: String?

    private var groups: [AppGroupRecordFfi] = []
    private var latestByGroup: [String: AppMessageRecordFfi] = [:]
    private var memberInfoByGroup: [String: (count: Int, other: String?)] = [:]

    init(appState: AppState) {
        self.appState = appState
    }

    deinit {
        chatsTask?.cancel()
        messagesTask?.cancel()
    }

    /// Begin (or rebind, when `accountRef` changes) the chats subscription.
    func bind(accountRef: String?, force: Bool = false) async {
        if currentAccount == accountRef, !force { return }
        chatsTask?.cancel(); chatsTask = nil
        messagesTask?.cancel(); messagesTask = nil
        groups = []
        latestByGroup = [:]
        memberInfoByGroup = [:]
        items = []
        loadError = nil
        currentAccount = accountRef

        guard let accountRef, let appState else { return }
        isLoading = true
        do {
            // Include archived so we can surface them in a separate view; the
            // main list filters them out in `recompute`.
            let chatsSub = try await appState.marmot.subscribeChats(
                accountRef: accountRef,
                includeArchived: true
            )
            groups = chatsSub.snapshot()
            isLoading = false
            await refreshLatest()
            recompute()
            for group in groups {
                await refreshMembers(groupIdHex: group.groupIdHex)
            }

            chatsTask = Task { [weak self] in
                for await update in SubscriptionDriver.chats(chatsSub) {
                    self?.foldGroup(update)
                }
            }

            let messagesSub = try await appState.marmot.subscribeMessages(
                accountRef: accountRef,
                groupIdHex: nil
            )
            messagesTask = Task { [weak self] in
                for await _ in SubscriptionDriver.messages(messagesSub) {
                    await self?.refreshLatest()
                }
            }
        } catch {
            isLoading = false
            loadError = error.localizedDescription
        }
    }

    /// Re-pull the latest message per group from the local store. Cheap enough
    /// to run on every message event and whenever the list reappears (which is
    /// how messages we sent ourselves get reflected in the preview).
    func refreshLatest() async {
        guard let accountRef = currentAccount, let appState else { return }
        do {
            let recent = try appState.marmot.messages(
                accountRef: accountRef,
                groupIdHex: nil,
                limit: 400
            )
            var newest: [String: AppMessageRecordFfi] = [:]
            for message in recent {
                // Skip control envelopes / reactions / deletes so the preview
                // shows the latest real message, never raw payload JSON.
                guard MessagePreview.isPreviewable(message) else { continue }
                if let existing = newest[message.groupIdHex],
                   existing.recordedAt >= message.recordedAt {
                    continue
                }
                newest[message.groupIdHex] = message
            }
            latestByGroup = newest
            recompute()
        } catch {
            // Non-fatal: previews simply won't refresh this cycle.
        }
    }

    /// Reflect a locally-produced group change (e.g. an archive toggle) right
    /// away. The chats subscription only emits on transport events, so local
    /// projection writes (setGroupArchived) won't otherwise update the list.
    func applyLocalGroupChange(_ record: AppGroupRecordFfi) {
        foldGroup(record)
    }

    private func foldGroup(_ record: AppGroupRecordFfi) {
        if let idx = groups.firstIndex(where: { $0.groupIdHex == record.groupIdHex }) {
            groups[idx] = record
        } else {
            groups.append(record)
        }
        recompute()
        Task { [weak self] in await self?.refreshMembers(groupIdHex: record.groupIdHex) }
    }

    private func refreshMembers(groupIdHex: String) async {
        guard let accountRef = currentAccount, let appState else { return }
        do {
            let members = try await appState.marmot.groupMembers(
                accountRef: accountRef,
                groupIdHex: groupIdHex
            )
            let me = appState.activeAccount?.accountIdHex
            let other = GroupDisplay.otherMemberAccount(in: members, myAccountId: me)
            memberInfoByGroup[groupIdHex] = (count: members.count, other: other)
            recompute()
        } catch {
            // ignore — title falls back to group name / id.
        }
    }

    private func recompute() {
        let all = groups.map { group -> Item in
            let info = memberInfoByGroup[group.groupIdHex]
            return Item(
                group: group,
                latest: latestByGroup[group.groupIdHex],
                otherMemberAccount: info?.other,
                memberCount: info?.count ?? 0
            )
        }
        items = all.filter { !$0.group.archived }.sorted(by: Self.sortRule)
        archivedItems = all.filter { $0.group.archived }.sorted(by: Self.sortRule)
    }

    /// Newest activity first; groups with no messages fall back to name order.
    private static let sortRule: (Item, Item) -> Bool = { a, b in
        switch (a.latest?.recordedAt, b.latest?.recordedAt) {
        case let (ta?, tb?) where ta != tb:
            return ta > tb
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            let nameA = a.group.name.isEmpty ? a.group.groupIdHex : a.group.name
            let nameB = b.group.name.isEmpty ? b.group.groupIdHex : b.group.name
            return nameA.localizedCaseInsensitiveCompare(nameB) == .orderedAscending
        }
    }
}

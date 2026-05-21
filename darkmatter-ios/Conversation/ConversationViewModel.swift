import Foundation
import Observation
import MarmotKit

/// Owns the live state of a single conversation: the merged timeline of
/// messages + system events, current group roster, and the send pipeline.
@Observable
final class ConversationViewModel {

    private(set) var timeline: [TimelineItem] = []
    private(set) var group: AppGroupRecordFfi
    private(set) var members: [AppGroupMemberRecordFfi] = []
    private(set) var isLoading = false
    private(set) var sendInFlight = false
    private(set) var error: String?

    private weak var appState: AppState?
    private var messagesTask: Task<Void, Never>?
    private var groupStateTask: Task<Void, Never>?

    /// The non-self member, used to title/avatar an unnamed 2-member group.
    var otherMember: String? {
        let me = appState?.activeAccount?.accountIdHex
        return members.first { $0.account != nil && $0.account != me }?.account
    }

    var displayTitle: String {
        guard let appState else {
            if let name = ProfileSanitizer.groupName(group.name) { return name }
            return IdentityFormatter.short(group.groupIdHex)
        }
        return GroupDisplay.title(group: group, otherMember: otherMember, appState: appState)
    }

    var displaySubtitle: String {
        let memberCount = members.count
        if memberCount == 0 { return "Just you" }
        let suffix = memberCount == 1 ? "member" : "members"
        return "\(memberCount) \(suffix)"
    }

    init(appState: AppState, group: AppGroupRecordFfi) {
        self.appState = appState
        self.group = group
    }

    deinit {
        messagesTask?.cancel()
        groupStateTask?.cancel()
    }

    /// Wires both subscriptions and seeds the initial state.
    func start() async {
        guard let appState, let accountRef = appState.activeAccountRef else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let messagesSub = try await appState.marmot.subscribeMessages(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )
            timeline = messagesSub.snapshot()
                .map { TimelineItem.message($0) }
                .sorted { $0.timestamp < $1.timestamp }

            let groupSub = try await appState.marmot.subscribeGroupState(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )
            if let initial = groupSub.snapshot() {
                group = initial
            }

            members = try await appState.marmot.groupMembers(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )

            messagesTask = Task { [weak self] in
                for await update in SubscriptionDriver.messages(messagesSub) {
                    await self?.fold(update)
                }
            }

            groupStateTask = Task { [weak self] in
                for await record in SubscriptionDriver.groupState(groupSub) {
                    await self?.applyGroupUpdate(record)
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func fold(_ update: MessageUpdateFfi) {
        let record: AppMessageRecordFfi
        switch update {
        case .message(let m): record = receivedToRecord(m)
        case .agentStreamStarted(let m): record = receivedToRecord(m)
        case .agentStreamFinalized(let m): record = receivedToRecord(m)
        }
        if let idx = timeline.firstIndex(where: { item in
            if case .message(let existing, _) = item.kind {
                return existing.messageIdHex == record.messageIdHex
                    && !record.messageIdHex.isEmpty
            }
            return false
        }) {
            timeline[idx] = .message(record)
        } else {
            timeline.append(.message(record))
        }
        timeline.sort { $0.timestamp < $1.timestamp }
    }

    private func receivedToRecord(_ r: RuntimeMessageReceivedFfi) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: r.message.messageIdHex,
            direction: "received",
            groupIdHex: r.message.groupIdHex,
            sender: r.message.sender,
            plaintext: r.message.plaintext,
            recordedAt: UInt64(Date().timeIntervalSince1970),
            receivedAt: UInt64(Date().timeIntervalSince1970)
        )
    }

    private func applyGroupUpdate(_ record: AppGroupRecordFfi) async {
        let previousName = group.name
        let wasArchived = group.archived
        group = record

        if !previousName.isEmpty && previousName != record.name {
            appendSystemEvent(.groupRenamed(record.name))
        }
        if record.archived && !wasArchived {
            appendSystemEvent(.groupArchived)
        } else if !record.archived && wasArchived {
            appendSystemEvent(.groupUnarchived)
        }

        // Refresh roster — membership changes are projected through the same
        // GroupStateUpdated event, so any group-record update could mean a
        // roster delta. Re-fetch to be safe.
        await refreshMembers()
    }

    private func appendSystemEvent(_ event: SystemEvent) {
        let now = UInt64(Date().timeIntervalSince1970)
        timeline.append(.systemEvent(id: UUID().uuidString, event: event, timestamp: now))
        timeline.sort { $0.timestamp < $1.timestamp }
    }

    private func refreshMembers() async {
        guard let appState, let accountRef = appState.activeAccountRef else { return }
        do {
            let next = try await appState.marmot.groupMembers(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )
            if next.map(\.memberIdHex) != members.map(\.memberIdHex) {
                appendSystemEvent(.rosterChanged)
            }
            members = next
        } catch {
            // Silent on membership refresh failures; the next subscription
            // tick will retry.
        }
    }

    // MARK: - Send

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let appState,
              let accountRef = appState.activeAccountRef else { return }

        // Optimistically render the message right away — the runtime emits no
        // event for messages we send, so the live subscription never echoes
        // them; this bubble is the only realtime representation.
        let tempId = UUID().uuidString
        let now = UInt64(Date().timeIntervalSince1970)
        let optimistic = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: group.groupIdHex,
            sender: appState.activeAccount?.accountIdHex ?? "",
            plaintext: trimmed,
            recordedAt: now,
            receivedAt: now
        )
        timeline.append(.pendingMessage(tempId: tempId, record: optimistic))
        timeline.sort { $0.timestamp < $1.timestamp }

        sendInFlight = true
        defer { sendInFlight = false }
        do {
            let summary = try await appState.marmot.sendText(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex,
                text: trimmed
            )
            confirmSent(tempId: tempId, record: optimistic, messageId: summary.messageIds.first)
        } catch {
            markFailed(tempId: tempId)
            self.error = error.localizedDescription
            await MainActor.run {
                Haptics.error()
                appState.present(.error("Send failed", message: error.localizedDescription))
            }
        }
    }

    private func confirmSent(tempId: String, record: AppMessageRecordFfi, messageId: String?) {
        let realId = messageId ?? ""
        let confirmed = AppMessageRecordFfi(
            messageIdHex: realId,
            direction: "sent",
            groupIdHex: record.groupIdHex,
            sender: record.sender,
            plaintext: record.plaintext,
            recordedAt: record.recordedAt,
            receivedAt: record.receivedAt
        )
        let rowId = "msg:\(realId.isEmpty ? tempId : realId)"
        if let idx = timeline.firstIndex(where: { $0.id == "msg:\(tempId)" }) {
            timeline[idx] = TimelineItem(
                id: rowId,
                kind: .message(record: confirmed, status: .sent),
                timestamp: confirmed.recordedAt
            )
        }
    }

    private func markFailed(tempId: String) {
        guard let idx = timeline.firstIndex(where: { $0.id == "msg:\(tempId)" }),
              case .message(let record, _) = timeline[idx].kind else { return }
        timeline[idx] = TimelineItem(
            id: "msg:\(tempId)",
            kind: .message(record: record, status: .failed),
            timestamp: record.recordedAt
        )
    }
}

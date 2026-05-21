import Foundation
import Observation
import MarmotKit

/// Owns the live state of a single conversation: the merged timeline of
/// message bubbles + system events, aggregated reactions, the group roster,
/// the in-progress reply, and the send pipeline.
@Observable
final class ConversationViewModel {

    /// One emoji's tally on a target message.
    struct ReactionTally: Identifiable, Hashable {
        let emoji: String
        let count: Int
        let mine: Bool
        var id: String { emoji }
    }

    private(set) var timeline: [TimelineItem] = []
    private(set) var group: AppGroupRecordFfi
    private(set) var members: [AppGroupMemberRecordFfi] = []
    /// targetMessageId → emoji tallies, derived from reaction messages.
    private(set) var reactions: [String: [ReactionTally]] = [:]
    private(set) var isLoading = false
    private(set) var sendInFlight = false
    private(set) var error: String?

    /// The message the composer is currently replying to (set by swipe / menu).
    var replyingTo: AppMessageRecordFfi?

    private weak var appState: AppState?
    private var messagesTask: Task<Void, Never>?
    private var groupStateTask: Task<Void, Never>?

    /// All messages we've seen by id, for reply-target lookups.
    private var messageById: [String: AppMessageRecordFfi] = [:]
    /// Reaction messages by their own id (incl. optimistic), re-aggregated on change.
    private var reactionRecords: [String: AppMessageRecordFfi] = [:]

    var myAccountId: String? { appState?.activeAccount?.accountIdHex }

    var otherMember: String? {
        let me = myAccountId
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

    var isSelfAdmin: Bool {
        guard let me = myAccountId else { return false }
        return group.admins.contains(me)
    }

    var isLastAdmin: Bool {
        isSelfAdmin && group.admins.count <= 1
    }

    func isAdmin(_ member: AppGroupMemberRecordFfi) -> Bool {
        if group.admins.contains(member.memberIdHex) { return true }
        if let account = member.account { return group.admins.contains(account) }
        return false
    }

    /// Reaction tallies for a target message (empty when none).
    func reactions(for messageIdHex: String) -> [ReactionTally] {
        reactions[messageIdHex] ?? []
    }

    /// The quoted preview (sender name + text) for a reply bubble, if resolvable.
    func replyPreview(for record: AppMessageRecordFfi) -> (name: String, text: String)? {
        guard case .reply(let targetId, _)? = record.appMessage else { return nil }
        guard let target = messageById[targetId] else { return nil }
        let name = appState?.displayName(forAccountIdHex: target.sender) ?? "Unknown"
        let text = ProfileSanitizer.singleLine(displayBody(of: target), maxLength: 120) ?? ""
        return (name, text)
    }

    /// The visible body for a message — reply text for replies, else plaintext.
    func displayBody(of record: AppMessageRecordFfi) -> String {
        if case .reply(_, let text)? = record.appMessage { return text }
        return record.plaintext
    }

    init(appState: AppState, group: AppGroupRecordFfi) {
        self.appState = appState
        self.group = group
    }

    deinit {
        messagesTask?.cancel()
        groupStateTask?.cancel()
    }

    func start() async {
        guard let appState, let accountRef = appState.activeAccountRef else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let messagesSub = try await appState.marmot.subscribeMessages(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )
            for record in messagesSub.snapshot() { ingest(record) }

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

    // MARK: - Ingestion

    private func fold(_ update: MessageUpdateFfi) {
        switch update {
        case .message(let m), .agentStreamStarted(let m), .agentStreamFinalized(let m):
            ingest(receivedToRecord(m))
        }
    }

    /// Route a message record to the timeline or the reactions index.
    private func ingest(_ record: AppMessageRecordFfi) {
        if !record.messageIdHex.isEmpty {
            messageById[record.messageIdHex] = record
        }
        switch record.appMessage {
        case .reaction?:
            reactionRecords[reactionKey(record)] = record
            recomputeReactions()
        case .delete?, .retry?:
            break // not rendered as bubbles
        default:
            upsertBubble(record) // reply, media, or plain text
        }
    }

    private func upsertBubble(_ record: AppMessageRecordFfi) {
        if !record.messageIdHex.isEmpty,
           let idx = timeline.firstIndex(where: { item in
               if case .message(let existing, _) = item.kind {
                   return existing.messageIdHex == record.messageIdHex
               }
               return false
           }) {
            timeline[idx] = .message(record)
        } else {
            timeline.append(.message(record))
        }
        timeline.sort { $0.timestamp < $1.timestamp }
    }

    private func reactionKey(_ record: AppMessageRecordFfi) -> String {
        record.messageIdHex.isEmpty ? UUID().uuidString : record.messageIdHex
    }

    /// Rebuild the per-target reaction tallies from all reaction messages,
    /// processed oldest-first so adds/removes net out per (sender, emoji).
    private func recomputeReactions() {
        let me = myAccountId ?? ""
        let ordered: [AppMessageRecordFfi] = reactionRecords.values
            .sorted { $0.recordedAt < $1.recordedAt }

        var byTarget: [String: [String: Set<String>]] = [:] // target -> emoji -> senders
        for record in ordered {
            guard case .reaction(let target, let emoji, let removed)? = record.appMessage else { continue }
            var emojis: [String: Set<String>] = byTarget[target] ?? [:]
            if removed {
                for key in emojis.keys {
                    emojis[key]?.remove(record.sender)
                }
            } else if !emoji.isEmpty {
                var senders: Set<String> = emojis[emoji] ?? []
                senders.insert(record.sender)
                emojis[emoji] = senders
            }
            byTarget[target] = emojis
        }

        var result: [String: [ReactionTally]] = [:]
        for (target, emojis) in byTarget {
            var tallies: [ReactionTally] = []
            for (emoji, senders) in emojis where !senders.isEmpty {
                tallies.append(ReactionTally(emoji: emoji, count: senders.count, mine: senders.contains(me)))
            }
            guard !tallies.isEmpty else { continue }
            tallies.sort { lhs, rhs in
                lhs.count == rhs.count ? lhs.emoji < rhs.emoji : lhs.count > rhs.count
            }
            result[target] = tallies
        }
        reactions = result
    }

    private func receivedToRecord(_ r: RuntimeMessageReceivedFfi) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: r.message.messageIdHex,
            direction: "received",
            groupIdHex: r.message.groupIdHex,
            sender: r.message.sender,
            plaintext: r.message.plaintext,
            appMessage: r.message.appMessage,
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
            // Silent; the next subscription tick will retry.
        }
    }

    // MARK: - Send

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let appState,
              let accountRef = appState.activeAccountRef else { return }

        let replyTargetId = replyTargetMessageId()
        let tempId = UUID().uuidString
        let now = UInt64(Date().timeIntervalSince1970)
        let optimisticPayload: AppMessagePayloadFfi? = replyTargetId.map {
            .reply(targetMessageId: $0, text: trimmed)
        }
        let optimistic = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: group.groupIdHex,
            sender: appState.activeAccount?.accountIdHex ?? "",
            plaintext: trimmed,
            appMessage: optimisticPayload,
            recordedAt: now,
            receivedAt: now
        )
        timeline.append(.pendingMessage(tempId: tempId, record: optimistic))
        timeline.sort { $0.timestamp < $1.timestamp }
        replyingTo = nil

        sendInFlight = true
        defer { sendInFlight = false }
        do {
            let summary: SendSummaryFfi
            if let replyTargetId {
                summary = try await appState.marmot.replyToMessage(
                    accountRef: accountRef,
                    groupIdHex: group.groupIdHex,
                    targetMessageId: replyTargetId,
                    text: trimmed
                )
            } else {
                summary = try await appState.marmot.sendText(
                    accountRef: accountRef,
                    groupIdHex: group.groupIdHex,
                    text: trimmed
                )
            }
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

    private func replyTargetMessageId() -> String? {
        guard let replyingTo, !replyingTo.messageIdHex.isEmpty else { return nil }
        return replyingTo.messageIdHex
    }

    private func confirmSent(tempId: String, record: AppMessageRecordFfi, messageId: String?) {
        let realId = messageId ?? ""
        let confirmed = AppMessageRecordFfi(
            messageIdHex: realId,
            direction: "sent",
            groupIdHex: record.groupIdHex,
            sender: record.sender,
            plaintext: record.plaintext,
            appMessage: record.appMessage,
            recordedAt: record.recordedAt,
            receivedAt: record.receivedAt
        )
        if !realId.isEmpty { messageById[realId] = confirmed }
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

    // MARK: - Reactions

    func toggleReaction(_ emoji: String, on message: AppMessageRecordFfi) async {
        guard let appState, let accountRef = appState.activeAccountRef,
              !message.messageIdHex.isEmpty else { return }
        let alreadyMine = reactions(for: message.messageIdHex).contains { $0.emoji == emoji && $0.mine }

        // Optimistic: synthesize a reaction record and re-aggregate.
        let me = appState.activeAccount?.accountIdHex ?? ""
        let synthetic = AppMessageRecordFfi(
            messageIdHex: "optimistic-\(UUID().uuidString)",
            direction: "sent",
            groupIdHex: group.groupIdHex,
            sender: me,
            plaintext: "",
            appMessage: .reaction(targetMessageId: message.messageIdHex, emoji: alreadyMine ? "" : emoji, removed: alreadyMine),
            recordedAt: UInt64(Date().timeIntervalSince1970),
            receivedAt: UInt64(Date().timeIntervalSince1970)
        )
        reactionRecords[synthetic.messageIdHex] = synthetic
        recomputeReactions()
        Haptics.tap()

        do {
            if alreadyMine {
                _ = try await appState.marmot.unreactFromMessage(
                    accountRef: accountRef,
                    groupIdHex: group.groupIdHex,
                    targetMessageId: message.messageIdHex
                )
            } else {
                _ = try await appState.marmot.reactToMessage(
                    accountRef: accountRef,
                    groupIdHex: group.groupIdHex,
                    targetMessageId: message.messageIdHex,
                    emoji: emoji
                )
            }
        } catch {
            // Revert the optimistic change.
            reactionRecords.removeValue(forKey: synthetic.messageIdHex)
            recomputeReactions()
            Haptics.error()
            appState.present(.error("Reaction failed", message: error.localizedDescription))
        }
    }
}

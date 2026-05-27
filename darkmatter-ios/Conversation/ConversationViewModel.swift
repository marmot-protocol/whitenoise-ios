import Foundation
import Observation
import MarmotKit
import os

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
    private(set) var groupMemberDetails: [GroupMemberDetailsFfi] = []
    private(set) var managementState: GroupManagementStateFfi?
    /// targetMessageId → emoji tallies, derived from reaction messages.
    private(set) var reactions: [String: [ReactionTally]] = [:]
    /// Message ids tombstoned by a delete payload (rendered as a placeholder).
    private(set) var deletedMessageIds: Set<String> = []
    private(set) var isLoading = false
    private(set) var sendInFlight = false
    private(set) var error: String?

    /// The message the composer is currently replying to (set by swipe / menu).
    var replyingTo: AppMessageRecordFfi?

    private weak var appState: AppState?
    private let initialOtherMember: String?
    private let initialMemberCount: Int?
    private var messagesTask: Task<Void, Never>?
    private var groupStateTask: Task<Void, Never>?

    /// All messages we've seen by id, for reply-target lookups.
    private var messageById: [String: AppMessageRecordFfi] = [:]
    /// Reaction messages by their own id (incl. optimistic), re-aggregated on change.
    private var reactionRecords: [String: AppMessageRecordFfi] = [:]
    /// Live agent-stream watch tasks, keyed by stream id.
    private var streamWatchTasks: [String: Task<Void, Never>] = [:]
    /// Accumulated text per live stream, keyed by stream id.
    private var streamText: [String: String] = [:]
    /// Streams whose final anchor message has arrived. Once finalized, the
    /// anchor's full text is authoritative and late live updates are ignored.
    private var finalizedStreamIds: Set<String> = []

    /// Live diagnostics for the agent-text-stream watch. Visible in the Xcode
    /// console (and Console.app) under category "agent-stream". We log sizes and
    /// counts rather than message text to avoid leaking chat content.
    private static let streamLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.darkmatter",
        category: "agent-stream"
    )

    var myAccountId: String? { appState?.activeAccount?.accountIdHex }

    /// The other participant's account id (pubkey hex) in a 1:1 chat: the first
    /// member that isn't us. `memberIdHex` is the pubkey hex (same space as
    /// `accountIdHex`); `member.account` is a local-only label, not comparable.
    var otherMember: String? {
        GroupDisplay.otherMemberAccount(in: members, myAccountId: myAccountId)
            ?? initialOtherMember
    }

    private var displayMemberCount: Int {
        if !members.isEmpty { return members.count }
        if !groupMemberDetails.isEmpty { return groupMemberDetails.count }
        return initialMemberCount ?? 0
    }

    var displayTitle: String {
        guard let appState else {
            if let name = ProfileSanitizer.groupName(group.name) { return name }
            return IdentityFormatter.short(group.groupIdHex)
        }
        return GroupDisplay.title(
            group: group,
            otherMember: otherMember,
            memberCount: displayMemberCount,
            appState: appState
        )
    }

    var displaySubtitle: String {
        let memberCount = displayMemberCount
        if memberCount == 0 { return L10n.string("Just you") }
        return memberCount == 1
            ? L10n.string("1 member")
            : L10n.string("\(memberCount) members")
    }

    var isSelfAdmin: Bool {
        if let managementState { return managementState.isSelfAdmin }
        guard let me = myAccountId else { return false }
        return group.admins.contains(me)
    }

    var isLastAdmin: Bool {
        if let managementState { return managementState.isLastAdmin }
        return isSelfAdmin && group.admins.count <= 1
    }

    func isAdmin(_ member: AppGroupMemberRecordFfi) -> Bool {
        if let detail = groupMemberDetails.first(where: { $0.memberIdHex == member.memberIdHex }) {
            return detail.isAdmin
        }
        if group.admins.contains(member.memberIdHex) { return true }
        if let account = member.account { return group.admins.contains(account) }
        return false
    }

    func managementAction(for memberIdHex: String) -> GroupMemberActionStateFfi? {
        managementState?.memberActions.first { $0.memberIdHex == memberIdHex }
    }

    /// Reaction tallies for a target message (empty when none).
    func reactions(for messageIdHex: String) -> [ReactionTally] {
        reactions[messageIdHex] ?? []
    }

    /// The quoted preview (sender name + text) for a reply bubble, if resolvable.
    func replyPreview(for record: AppMessageRecordFfi) -> (name: String, text: String)? {
        guard case .reply(let targetId) = MessageSemantics.classify(record) else { return nil }
        guard let target = messageById[targetId] else { return nil }
        let name = appState?.displayName(forAccountIdHex: target.sender) ?? L10n.string("Unknown")
        let text = ProfileSanitizer.singleLine(displayBody(of: target), maxLength: 120) ?? ""
        return (name, text)
    }

    /// The visible body for a message, projected from the decoded unsigned
    /// Nostr app event's kind/tags/content.
    func displayBody(of record: AppMessageRecordFfi) -> String {
        MessagePreview.body(record)
    }

    init(
        appState: AppState,
        group: AppGroupRecordFfi,
        initialOtherMember: String? = nil,
        initialMemberCount: Int? = nil
    ) {
        self.appState = appState
        self.group = group
        self.initialOtherMember = initialOtherMember
        self.initialMemberCount = initialMemberCount
    }

    deinit {
        messagesTask?.cancel()
        groupStateTask?.cancel()
        for task in streamWatchTasks.values { task.cancel() }
    }

    func start() async {
        guard let appState, let accountRef = appState.activeAccountRef else { return }
        stopLiveSubscriptions()
        isLoading = true
        defer { isLoading = false }

        do {
            let messagesSub = try await appState.marmot.subscribeMessages(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )
            let snapshot = messagesSub.snapshot()
            for record in snapshot { ingest(record) }
            for record in snapshot { watchSnapshotStartIfNeeded(record) }

            let groupSub = try await appState.marmot.subscribeGroupState(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )
            if let initial = groupSub.snapshot() {
                group = initial
            }

            if !(await refreshGroupManagement()) {
                members = try await appState.marmot.groupMembers(
                    accountRef: accountRef,
                    groupIdHex: group.groupIdHex
                )
            }

            messagesTask = Task { [weak self] in
                for await update in SubscriptionDriver.messages(messagesSub) {
                    self?.fold(update)
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

    private func stopLiveSubscriptions() {
        messagesTask?.cancel()
        messagesTask = nil
        groupStateTask?.cancel()
        groupStateTask = nil
        for task in streamWatchTasks.values {
            task.cancel()
        }
        streamWatchTasks.removeAll()
    }

    private func watchSnapshotStartIfNeeded(_ record: AppMessageRecordFfi) {
        guard let streamIdHex = Self.snapshotStartStreamIdToWatch(
            from: record,
            finalizedStreamIds: finalizedStreamIds
        ) else { return }
        Task { [weak self] in await self?.startWatching(sender: record.sender, streamIdHex: streamIdHex) }
    }

    static func snapshotStartStreamIdToWatch(
        from record: AppMessageRecordFfi,
        finalizedStreamIds: Set<String>
    ) -> String? {
        guard case .agentStreamStart(let start) = MessageSemantics.classify(record),
              let streamIdHex = MessageSemantics.normalizedStreamId(start.streamId),
              !finalizedStreamIds.contains(streamIdHex)
        else { return nil }
        return streamIdHex
    }

    // MARK: - Ingestion

    private func fold(_ update: MessageUpdateFfi) {
        switch update {
        case .message(let m):
            ingest(Self.receivedToRecord(m, now: UInt64(Date().timeIntervalSince1970)))
        case .agentStreamStarted(let m):
            // A kind-1200 start: open a live bubble and watch the QUIC stream as
            // it fills in. The stream id lives on the inner event's `stream` tag.
            let sender = m.message.sender
            let streamIdHex = Self.agentStreamId(from: m.message)
            Self.streamLog.info("start received: streamId=\(streamIdHex ?? "<latest>", privacy: .public) sender=\(IdentityFormatter.short(sender), privacy: .public)")
            Task { [weak self] in await self?.startWatching(sender: sender, streamIdHex: streamIdHex) }
        }
    }

    /// Tear down a live preview that produced no usable transcript (the stream
    /// failed). agentnoise falls back to a plain chat reply in that case, which
    /// arrives as a normal message — so drop the preview and mark the stream
    /// finalized so trailing updates can't recreate it.
    private func endStream(streamId: String) {
        finalizedStreamIds.insert(streamId)
        streamWatchTasks[streamId]?.cancel()
        streamWatchTasks[streamId] = nil
        streamText[streamId] = nil
        removeStreamBubble(streamId: streamId)
    }

    /// Promote the transient live preview into a permanent received bubble
    /// carrying the final transcript. The Final MLS anchor is authoritative; the
    /// QUIC `.finished` transcript is a provisional fill if it lands first. Both
    /// key the same `msg:stream:<id>` row, so whichever arrives later wins.
    private func finalizeStreamBubble(streamId: String, sender: String, text: String) {
        streamText[streamId] = text
        upsertStreamBubble(streamId: streamId, sender: sender, status: .received)
        finalizedStreamIds.insert(streamId)
        streamWatchTasks[streamId]?.cancel()
        streamWatchTasks[streamId] = nil
    }

    private func removeStreamBubble(streamId: String) {
        timeline.removeAll { $0.id == "msg:stream:\(streamId)" }
    }

    /// Route a message record to the timeline or the reactions index by
    /// branching on its inner-event kind + tags.
    private func ingest(_ record: AppMessageRecordFfi) {
        switch MessageSemantics.classify(record) {
        case .agentStreamStart, .unknown:
            // The kind-1200 start signal isn't a chat bubble; it's handled by
            // `fold` opening the live preview. Unknown kinds aren't rendered.
            return
        case .streamFinal(let streamId):
            // The kind-9 stream-final is the canonical record: its plaintext is
            // the full transcript. Promote the live preview into a permanent
            // bubble, matching on the `stream` tag value.
            if !record.messageIdHex.isEmpty { messageById[record.messageIdHex] = record }
            Self.streamLog.info("FINAL message in: streamId=\(streamId, privacy: .public) sender=\(IdentityFormatter.short(record.sender), privacy: .public) textLen=\(record.plaintext.count)B — promoting preview to permanent bubble")
            finalizeStreamBubble(streamId: streamId, sender: record.sender, text: record.plaintext)
        case .reaction:
            if !record.messageIdHex.isEmpty { messageById[record.messageIdHex] = record }
            reactionRecords[reactionKey(record)] = record
            recomputeReactions()
        case .delete(let target):
            if !record.messageIdHex.isEmpty { messageById[record.messageIdHex] = record }
            // A delete tombstones either a chat message or a reaction event id;
            // recompute reactions so an un-react (delete of a kind-7) drops it.
            deletedMessageIds.insert(target)
            recomputeReactions()
        case .chat, .reply, .media:
            if !record.messageIdHex.isEmpty { messageById[record.messageIdHex] = record }
            upsertBubble(record)
        }
    }

    func isDeleted(_ messageIdHex: String) -> Bool {
        deletedMessageIds.contains(messageIdHex)
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

    /// Rebuild the per-target reaction tallies from all reaction messages
    /// (kind-7, emoji in content, target in the `e` tag). A reaction is dropped
    /// when its own event id has been tombstoned by a delete (the un-react path).
    private func recomputeReactions() {
        let me = myAccountId ?? ""
        let ordered: [AppMessageRecordFfi] = reactionRecords.values
            .sorted { $0.recordedAt < $1.recordedAt }

        var byTarget: [String: [String: Set<String>]] = [:] // target -> emoji -> senders
        for record in ordered {
            guard case .reaction(let target) = MessageSemantics.classify(record) else { continue }
            // Un-react: the reaction event was deleted (kind-5 on its id).
            if !record.messageIdHex.isEmpty, deletedMessageIds.contains(record.messageIdHex) {
                continue
            }
            let emoji = record.plaintext
            var emojis: [String: Set<String>] = byTarget[target] ?? [:]
            if !emoji.isEmpty {
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

    /// Prefer the event's own `recordedAt` so the timeline sorts by send time;
    /// fall back to `now` only when the FFI omitted it (zero sentinel).
    static func receivedToRecord(_ r: RuntimeMessageReceivedFfi, now: UInt64) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: r.message.messageIdHex,
            direction: "received",
            groupIdHex: r.message.groupIdHex,
            sender: r.message.sender,
            plaintext: r.message.plaintext,
            kind: r.message.kind,
            tags: r.message.tags,
            recordedAt: r.message.recordedAt > 0 ? r.message.recordedAt : now,
            receivedAt: now
        )
    }

    private func applyGroupUpdate(_ record: AppGroupRecordFfi) async {
        let previousName = group.name
        let wasArchived = group.archived
        group = record

        if !previousName.isEmpty && previousName != record.name {
            appendSystemEvent(.groupRenamed(record.name))
            appState?.present(.success(L10n.string("Group renamed"), message: ProfileSanitizer.groupName(record.name)))
        }
        if record.archived && !wasArchived {
            appendSystemEvent(.groupArchived)
            appState?.present(.warning(L10n.string("Group archived")))
        } else if !record.archived && wasArchived {
            appendSystemEvent(.groupUnarchived)
            appState?.present(.success(L10n.string("Group unarchived")))
        }
        await refreshMembers()
    }

    func applyGroupRecord(_ record: AppGroupRecordFfi) {
        group = record
    }

    func applyGroupMutation(_ result: GroupMutationResultFfi) {
        applyGroupDetails(result.details, managementState: result.managementState)
    }

    func applyOptimisticAdminStatus(memberIdHex: String, isAdmin: Bool) {
        var updatedGroup = group
        if isAdmin {
            if !updatedGroup.admins.contains(memberIdHex) {
                updatedGroup.admins.append(memberIdHex)
            }
        } else {
            updatedGroup.admins.removeAll { $0 == memberIdHex }
        }
        group = updatedGroup

        groupMemberDetails = groupMemberDetails.map { member in
            guard member.memberIdHex == memberIdHex else { return member }
            var updated = member
            updated.isAdmin = isAdmin
            return updated
        }

        guard var state = managementState else { return }
        if memberIdHex == state.myAccountIdHex {
            state.isSelfAdmin = isAdmin
        }
        state.memberActions = state.memberActions.map { action in
            guard action.memberIdHex == memberIdHex else { return action }
            var updated = action
            updated.isAdmin = isAdmin
            updated.canPromote = state.isSelfAdmin && !updated.isSelf && !isAdmin
            updated.canDemote = state.isSelfAdmin && !updated.isSelf && isAdmin
            return updated
        }
        state.isLastAdmin = state.isSelfAdmin && group.admins.count <= 1
        state.requiresSelfDemoteBeforeLeave = state.isSelfAdmin
        state.canLeave = !state.requiresSelfDemoteBeforeLeave
        managementState = state
    }

    @discardableResult
    func refreshGroupManagement(announceRosterChanges: Bool = false) async -> Bool {
        guard let appState, let accountRef = appState.activeAccountRef else { return false }
        do {
            let details = try await appState.marmot.groupDetails(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )
            let state = try await appState.marmot.groupManagementState(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )
            applyGroupDetails(details, managementState: state, announceRosterChanges: announceRosterChanges)
            return true
        } catch {
            return false
        }
    }

    private func applyGroupDetails(
        _ details: GroupDetailsFfi,
        managementState state: GroupManagementStateFfi,
        announceRosterChanges: Bool = false
    ) {
        let nextMembers = details.members.map {
            AppGroupMemberRecordFfi(
                memberIdHex: $0.memberIdHex,
                account: $0.account,
                local: $0.local
            )
        }
        if announceRosterChanges && nextMembers.map(\.memberIdHex) != members.map(\.memberIdHex) {
            appendSystemEvent(.rosterChanged)
            appState?.present(.success(L10n.string("Group membership updated")))
        }
        group = details.group
        groupMemberDetails = details.members
        managementState = state
        members = nextMembers
    }

    private func appendSystemEvent(_ event: SystemEvent) {
        let now = UInt64(Date().timeIntervalSince1970)
        timeline.append(.systemEvent(id: UUID().uuidString, event: event, timestamp: now))
        timeline.sort { $0.timestamp < $1.timestamp }
    }

    private func refreshMembers() async {
        guard let appState, let accountRef = appState.activeAccountRef else { return }
        if await refreshGroupManagement(announceRosterChanges: true) {
            return
        }
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
        // A reply is a kind-9 with `e` + `q` tags pointing at the parent; a plain
        // message is a bare kind-9.
        let optimisticTags: [MessageTagFfi] = replyTargetId.map {
            [
                MessageTagFfi(values: [MessageSemantics.eventRefTag, $0]),
                MessageTagFfi(values: [MessageSemantics.quoteRefTag, $0]),
            ]
        } ?? []
        let optimistic = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: group.groupIdHex,
            sender: appState.activeAccount?.accountIdHex ?? "",
            plaintext: trimmed,
            kind: MessageSemantics.kindChat,
            tags: optimisticTags,
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
                appState.present(.error(L10n.string("Send failed"), message: error.localizedDescription))
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
            kind: record.kind,
            tags: record.tags,
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

    /// Tombstone our own message. Optimistically marks it deleted, then
    /// publishes the delete payload (reverting on failure).
    func deleteMessage(_ message: AppMessageRecordFfi) async {
        guard let appState, let accountRef = appState.activeAccountRef,
              !message.messageIdHex.isEmpty else { return }
        deletedMessageIds.insert(message.messageIdHex)
        do {
            _ = try await appState.marmot.deleteMessage(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex,
                targetMessageId: message.messageIdHex
            )
            Haptics.warning()
        } catch {
            deletedMessageIds.remove(message.messageIdHex)
            Haptics.error()
            appState.present(.error(L10n.string("Couldn't delete message"), message: error.localizedDescription))
        }
    }

    // MARK: - Agent text streaming

    /// The stream id of a kind-1200 start, read from its `stream` tag. Returns
    /// nil (watch the latest stream) if absent or malformed.
    static func agentStreamId(from message: ReceivedMessageFfi) -> String? {
        guard case .agentStreamStart(let start) = MessageSemantics.classify(message) else { return nil }
        return MessageSemantics.normalizedStreamId(start.streamId)
    }

    /// Watch a concrete live agent stream when the start payload names one;
    /// otherwise fall back to the latest live stream in this group.
    private func startWatching(sender: String, streamIdHex: String?) async {
        guard let appState, let accountRef = appState.activeAccountRef else { return }
        if let streamIdHex, streamWatchTasks[streamIdHex] != nil { return }
        do {
            let subscription = try await appState.marmot.watchAgentTextStream(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex,
                streamIdHex: streamIdHex,
                serverCertDer: nil,
                // Developer mode points at a loopback broker (insecure); release
                // builds use the platform TLS verifier against a real cert.
                insecureLocal: appState.developerMode
            )
            let streamId = subscription.streamIdHex()
            if streamWatchTasks[streamId] != nil { return }
            streamText[streamId] = ""
            upsertStreamBubble(streamId: streamId, sender: sender, status: .streaming)
            Self.streamLog.info("watch opened: streamId=\(streamId, privacy: .public) developerMode=\(appState.developerMode, privacy: .public); bubble shown as Streaming")
            let task = Task { [weak self] in
                while !Task.isCancelled, let update = await subscription.next() {
                    self?.applyStreamUpdate(streamId: streamId, sender: sender, update: update)
                }
            }
            streamWatchTasks[streamId] = task
        } catch {
            // No resolvable start payload yet, or the broker is unreachable.
            Self.streamLog.error("watch failed to open: streamId=\(streamIdHex ?? "<latest>", privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func applyStreamUpdate(streamId: String, sender: String, update: AgentStreamUpdateFfi) {
        // The final anchor already supplied the authoritative transcript.
        if finalizedStreamIds.contains(streamId) { return }
        switch update {
        case .chunk(_, let text):
            streamText[streamId, default: ""].append(text)
            upsertStreamBubble(streamId: streamId, sender: sender, status: .streaming)
        case .finished(let text, let transcriptHashHex, let chunkCount):
            // QUIC stream closed. Promote the preview to a permanent bubble using
            // the streamed transcript; the authoritative MLS Final anchor will
            // overwrite the same row if it arrives afterwards.
            Self.streamLog.info("finished: streamId=\(streamId, privacy: .public) chunkCount=\(chunkCount) textLen=\(text.count)B hashLen=\(transcriptHashHex.count) — promoting preview to permanent bubble")
            finalizeStreamBubble(streamId: streamId, sender: sender, text: text)
        case .failed(let message):
            Self.streamLog.error("failed: streamId=\(streamId, privacy: .public) gotText=\(self.streamText[streamId]?.count ?? 0)B reason=\(message, privacy: .public) — dropping live preview")
            endStream(streamId: streamId)
        }
    }

    /// Create or update the synthetic bubble for a live stream (keyed by id).
    private func upsertStreamBubble(streamId: String, sender: String, status: MessageStatus) {
        let rowId = "msg:stream:\(streamId)"
        let now = UInt64(Date().timeIntervalSince1970)
        let record = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "received",
            groupIdHex: group.groupIdHex,
            sender: sender,
            plaintext: streamText[streamId] ?? "",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: now,
            receivedAt: now
        )
        if let idx = timeline.firstIndex(where: { $0.id == rowId }) {
            let timestamp = timeline[idx].timestamp
            timeline[idx] = TimelineItem(
                id: rowId,
                kind: .message(record: record, status: status),
                timestamp: timestamp
            )
        } else {
            timeline.append(
                TimelineItem(id: rowId, kind: .message(record: record, status: status), timestamp: now)
            )
            timeline.sort { $0.timestamp < $1.timestamp }
        }
    }

    func toggleReaction(_ emoji: String, on message: AppMessageRecordFfi) async {
        guard let appState, let accountRef = appState.activeAccountRef,
              !message.messageIdHex.isEmpty else { return }
        let me = appState.activeAccount?.accountIdHex ?? ""
        let alreadyMine = reactions(for: message.messageIdHex).contains { $0.emoji == emoji && $0.mine }

        // Optimistic state we can roll back on failure.
        var addedKey: String?
        var removedRecords: [String: AppMessageRecordFfi] = [:]

        if alreadyMine {
            // Un-react: drop my matching reaction record(s) for this target+emoji.
            // The real un-react publishes a kind-5 delete of the reaction event id.
            for (key, record) in reactionRecords {
                guard record.sender == me, record.plaintext == emoji,
                      case .reaction(let target) = MessageSemantics.classify(record),
                      target == message.messageIdHex else { continue }
                removedRecords[key] = record
            }
            for key in removedRecords.keys { reactionRecords.removeValue(forKey: key) }
        } else {
            // Add: synthesize a kind-7 reaction (emoji in content, `e` tag target).
            let key = "optimistic-\(UUID().uuidString)"
            let synthetic = AppMessageRecordFfi(
                messageIdHex: key,
                direction: "sent",
                groupIdHex: group.groupIdHex,
                sender: me,
                plaintext: emoji,
                kind: MessageSemantics.kindReaction,
                tags: [MessageTagFfi(values: [MessageSemantics.eventRefTag, message.messageIdHex])],
                recordedAt: UInt64(Date().timeIntervalSince1970),
                receivedAt: UInt64(Date().timeIntervalSince1970)
            )
            reactionRecords[key] = synthetic
            addedKey = key
        }
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
            if let addedKey { reactionRecords.removeValue(forKey: addedKey) }
            for (key, record) in removedRecords { reactionRecords[key] = record }
            recomputeReactions()
            Haptics.error()
            appState.present(.error(L10n.string("Reaction failed"), message: error.localizedDescription))
        }
    }
}

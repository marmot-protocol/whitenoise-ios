import Foundation
import Observation
import MarmotKit
import os

/// Owns the live state of a single conversation: the merged timeline of
/// message bubbles + system events, aggregated reactions, the group roster,
/// the in-progress reply, and the send pipeline.
@Observable
@MainActor
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
    /// targetMessageId -> emoji tallies, derived from materialized timeline rows
    /// plus local optimistic reaction edits.
    private(set) var reactions: [String: [ReactionTally]] = [:]
    /// Message ids tombstoned by the timeline projection or local optimistic deletes.
    private(set) var deletedMessageIds: Set<String> = []
    private(set) var hasMoreBefore = false
    private(set) var isLoadingOlder = false
    private(set) var isLoading = false
    private(set) var sendInFlight = false
    private(set) var error: String?

    /// The message the composer is currently replying to (set by swipe / menu).
    var replyingTo: AppMessageRecordFfi?

    private weak var appState: AppState?
    private let initialTitle: String?
    private let initialOtherMember: String?
    private let initialMemberCount: Int?
    private let onChatListRowUpdated: ((ChatListRowFfi) -> Void)?
    private var timelineTask: Task<Void, Never>?
    private var groupStateTask: Task<Void, Never>?
    private var groupDetailsTask: Task<Void, Never>?
    private var readStateTask: Task<Void, Never>?

    private static let timelinePageLimit: UInt32 = 50
    private static let liveSubscriptionInitialRetryDelayNanoseconds: UInt64 = 500_000_000
    private static let liveSubscriptionMaximumRetryDelayNanoseconds: UInt64 = 8_000_000_000

    /// Renderable timeline messages we've loaded by id.
    private var messageById: [String: AppMessageRecordFfi] = [:]
    private var messageStatusById: [String: MessageStatus] = [:]
    private var replyTargetByMessageId: [String: String] = [:]
    private var replyPreviewsByMessageId: [String: TimelineReplyPreviewFfi] = [:]
    private var projectedReactionSummaries: [String: TimelineReactionSummaryFfi] = [:]
    private var projectedDeletedMessageIds: Set<String> = []
    private var optimisticDeletedMessageIds: Set<String> = []
    private var loadedOlderTimelinePages = false
    private var systemTimelineItems: [TimelineItem] = []
    private var transientTimelineItems: [String: TimelineItem] = [:]
    /// Optimistic reaction messages by their own temporary id, re-aggregated on change.
    private var reactionRecords: [String: AppMessageRecordFfi] = [:]
    private var optimisticReactionRemovals: Set<ReactionRemoval> = []
    /// Live agent-stream watch tasks, keyed by stream id.
    private var streamWatchTasks: [String: Task<Void, Never>] = [:]
    /// Accumulated text per live stream, keyed by stream id.
    private var streamText: [String: String] = [:]
    /// Streams whose final anchor message has arrived. Once finalized, the
    /// anchor's full text is authoritative and late live updates are ignored.
    private var finalizedStreamIds: Set<String> = []
    private var markedReadMessageIds: Set<String> = []

    /// Live diagnostics for the agent-text-stream watch. Visible in the Xcode
    /// console (and Console.app) under category "agent-stream". We log sizes and
    /// counts rather than message text to avoid leaking chat content.
    private static let streamLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.darkmatter",
        category: "agent-stream"
    )

    enum TimelinePagePlacement {
        case tail
        case older
    }

    private struct ReactionRemoval: Hashable {
        let targetMessageIdHex: String
        let emoji: String
        let sender: String
    }

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
            if let initialTitle = ProfileSanitizer.groupName(initialTitle) { return initialTitle }
            return IdentityFormatter.short(group.groupIdHex)
        }
        if members.isEmpty,
           groupMemberDetails.isEmpty,
           let initialTitle = ProfileSanitizer.groupName(initialTitle),
           ProfileSanitizer.groupName(group.name) == nil {
            return initialTitle
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
            : L10n.formatted("%lld members", Int64(memberCount))
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
        return false
    }

    func managementAction(for memberIdHex: String) -> GroupMemberActionStateFfi? {
        managementState?.memberActions.first { $0.memberIdHex == memberIdHex }
    }

    /// Reaction tallies for a target message (empty when none).
    func reactions(for messageIdHex: String) -> [ReactionTally] {
        reactions[messageIdHex] ?? []
    }

    func record(for messageIdHex: String) -> AppMessageRecordFfi? {
        messageById[messageIdHex]
    }

    /// The quoted preview (sender name + text) for a reply bubble, if resolvable.
    func replyPreview(for record: AppMessageRecordFfi) -> (name: String, text: String)? {
        let targetId: String?
        if let projectedTargetId = replyTargetByMessageId[record.messageIdHex] {
            targetId = projectedTargetId
        } else if case .reply(let semanticTargetId) = MessageSemantics.classify(record) {
            targetId = semanticTargetId
        } else {
            targetId = nil
        }
        guard let targetId else {
            return nil
        }
        if let preview = replyPreviewsByMessageId[record.messageIdHex] {
            let name = appState?.displayName(forAccountIdHex: preview.sender) ?? L10n.string("Unknown")
            let text = ProfileSanitizer.singleLine(MessagePreview.body(preview), maxLength: 120) ?? ""
            return (name, text)
        }
        guard let target = messageById[targetId] else {
            return nil
        }
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
        initialTitle: String? = nil,
        initialOtherMember: String? = nil,
        initialMemberCount: Int? = nil,
        onChatListRowUpdated: ((ChatListRowFfi) -> Void)? = nil
    ) {
        self.appState = appState
        self.group = group
        self.initialTitle = initialTitle
        self.initialOtherMember = initialOtherMember
        self.initialMemberCount = initialMemberCount
        self.onChatListRowUpdated = onChatListRowUpdated
    }

    isolated deinit {
        timelineTask?.cancel()
        groupStateTask?.cancel()
        groupDetailsTask?.cancel()
        readStateTask?.cancel()
        for task in streamWatchTasks.values { task.cancel() }
    }

    func start() async {
        guard let appState, let accountRef = appState.activeAccountRef else { return }
        stopLiveSubscriptions()
        error = nil
        startLiveTimeline(accountRef: accountRef)
        startLiveGroupState(accountRef: accountRef)
        startDeferredGroupDetails(accountRef: accountRef)
        startDeferredReadState()
    }

    func markReadIfVisible(_ record: AppMessageRecordFfi) async {
        guard Self.shouldMarkRead(
            record,
            isDeleted: isDeleted(record.messageIdHex),
            alreadyMarked: markedReadMessageIds.contains(record.messageIdHex)
        ),
            let appState,
            let accountRef = appState.activeAccountRef
        else { return }

        markedReadMessageIds.insert(record.messageIdHex)
        do {
            if let row = try appState.marmot.markTimelineMessageRead(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex,
                messageIdHex: record.messageIdHex
            ) {
                onChatListRowUpdated?(row)
            }
        } catch {
            markedReadMessageIds.remove(record.messageIdHex)
        }
    }

    static func shouldMarkRead(_ record: AppMessageRecordFfi, isDeleted: Bool, alreadyMarked: Bool) -> Bool {
        !alreadyMarked
            && !isDeleted
            && !record.messageIdHex.isEmpty
            && record.kind == MessageSemantics.kindChat
    }

    static func canDeleteMessage(
        _ message: AppMessageRecordFfi,
        myAccountId: String?,
        isSelfAdmin: Bool
    ) -> Bool {
        guard !message.messageIdHex.isEmpty else { return false }
        if isSelfAdmin { return true }
        guard let myAccountId, !myAccountId.isEmpty else { return false }
        return message.sender == myAccountId
    }

    static func nextLiveSubscriptionRetryDelay(after delay: UInt64) -> UInt64 {
        guard delay < liveSubscriptionMaximumRetryDelayNanoseconds else {
            return liveSubscriptionMaximumRetryDelayNanoseconds
        }
        let doubled = delay.multipliedReportingOverflow(by: 2)
        guard !doubled.overflow else { return liveSubscriptionMaximumRetryDelayNanoseconds }
        return min(doubled.partialValue, liveSubscriptionMaximumRetryDelayNanoseconds)
    }

    private func initializeReadState() {
        guard let appState, let accountRef = appState.activeAccountRef else { return }
        do {
            if let row = try appState.marmot.initializeChatReadState(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            ) {
                onChatListRowUpdated?(row)
            }
        } catch {
            // Read-state setup is opportunistic; the conversation itself still works.
        }
    }

    private func stopLiveSubscriptions() {
        timelineTask?.cancel()
        timelineTask = nil
        groupStateTask?.cancel()
        groupStateTask = nil
        groupDetailsTask?.cancel()
        groupDetailsTask = nil
        readStateTask?.cancel()
        readStateTask = nil
        for task in streamWatchTasks.values {
            task.cancel()
        }
        streamWatchTasks.removeAll()
    }

    private func startLiveTimeline(accountRef: String) {
        guard let appState else { return }
        let groupIdHex = group.groupIdHex
        timelineTask = Task { [weak self, weak appState] in
            var retryDelay = Self.liveSubscriptionInitialRetryDelayNanoseconds
            while !Task.isCancelled {
                do {
                    guard let appState else { return }
                    let timelineSub = try await appState.marmot.subscribeTimelineMessages(
                        accountRef: accountRef,
                        groupIdHex: groupIdHex,
                        limit: Self.timelinePageLimit
                    )
                    guard !Task.isCancelled else { return }
                    self?.error = nil
                    if let snapshot = timelineSub.snapshot() {
                        self?.applyTimelinePage(snapshot, placement: .tail)
                    }
                    for await update in SubscriptionDriver.timelineMessageUpdates(timelineSub) {
                        guard !Task.isCancelled else { return }
                        retryDelay = Self.liveSubscriptionInitialRetryDelayNanoseconds
                        self?.applyTimelineSubscriptionUpdate(update)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.error = error.localizedDescription
                }
                guard !Task.isCancelled else { return }
                do {
                    try await Task.sleep(nanoseconds: retryDelay)
                } catch {
                    return
                }
                retryDelay = Self.nextLiveSubscriptionRetryDelay(after: retryDelay)
            }
        }
    }

    private func startLiveGroupState(accountRef: String) {
        guard let appState else { return }
        let groupIdHex = group.groupIdHex
        groupStateTask = Task { [weak self, weak appState] in
            var retryDelay = Self.liveSubscriptionInitialRetryDelayNanoseconds
            while !Task.isCancelled {
                do {
                    guard let appState else { return }
                    let groupSub = try await appState.marmot.subscribeGroupState(
                        accountRef: accountRef,
                        groupIdHex: groupIdHex
                    )
                    guard !Task.isCancelled else { return }
                    if let initial = groupSub.snapshot() {
                        self?.group = initial
                    }
                    for await record in SubscriptionDriver.groupState(groupSub) {
                        guard !Task.isCancelled else { return }
                        retryDelay = Self.liveSubscriptionInitialRetryDelayNanoseconds
                        await self?.applyGroupUpdate(record)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.error = error.localizedDescription
                }
                guard !Task.isCancelled else { return }
                do {
                    try await Task.sleep(nanoseconds: retryDelay)
                } catch {
                    return
                }
                retryDelay = Self.nextLiveSubscriptionRetryDelay(after: retryDelay)
            }
        }
    }

    private func startDeferredGroupDetails(accountRef: String) {
        guard let appState else { return }
        let groupIdHex = group.groupIdHex
        groupDetailsTask = Task { [weak self, weak appState] in
            guard let self, let appState else { return }
            if await self.refreshGroupManagement() {
                return
            }
            guard !Task.isCancelled else { return }
            do {
                self.members = try await appState.marmot.groupMembers(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex
                )
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func startDeferredReadState() {
        readStateTask = Task { [weak self] in
            self?.initializeReadState()
        }
    }

    private func watchAgentStreamStartIfNeeded(_ record: AppMessageRecordFfi) {
        guard let streamIdHex = Self.agentStreamStartIdToWatch(
            from: record,
            finalizedStreamIds: finalizedStreamIds
        ) else { return }
        Task { [weak self] in await self?.startWatching(sender: record.sender, streamIdHex: streamIdHex) }
    }

    static func agentStreamStartIdToWatch(
        from record: AppMessageRecordFfi,
        finalizedStreamIds: Set<String>
    ) -> String? {
        guard case .agentStreamStart(let start) = MessageSemantics.classify(record),
              let streamIdHex = MessageSemantics.normalizedStreamId(start.streamId),
              !finalizedStreamIds.contains(streamIdHex)
        else { return nil }
        return streamIdHex
    }

    func applyTimelinePage(_ page: TimelinePageFfi, placement: TimelinePagePlacement) {
        for record in page.messages {
            applyTimelineRecord(record)
        }
        switch placement {
        case .tail:
            if !loadedOlderTimelinePages {
                hasMoreBefore = page.hasMoreBefore
            }
        case .older:
            loadedOlderTimelinePages = true
            hasMoreBefore = page.hasMoreBefore
        }
        rebuildProjectedState()
    }

    func applyTimelineSubscriptionUpdate(_ update: TimelineSubscriptionUpdateFfi) {
        switch update {
        case .page(let page):
            applyTimelinePage(page, placement: .tail)
        case .projection(let runtimeUpdate):
            applyTimelineProjectionUpdate(runtimeUpdate.update)
        }
    }

    private func applyTimelineProjectionUpdate(_ update: TimelineProjectionUpdateFfi) {
        guard update.groupIdHex == group.groupIdHex else { return }
        let rebuildTimelineAfterUpdate: Bool
        if update.changes.isEmpty {
            for record in update.messages {
                applyTimelineRecord(record, updateTimeline: update.messages.count == 1)
            }
            rebuildTimelineAfterUpdate = update.messages.count != 1
        } else {
            for change in update.changes {
                applyTimelineChange(change)
            }
            rebuildTimelineAfterUpdate = false
        }
        if let row = update.chatListRow {
            onChatListRowUpdated?(row)
        }
        rebuildProjectedState(rebuildTimeline: rebuildTimelineAfterUpdate)
    }

    private func applyTimelineChange(_ change: TimelineMessageChangeFfi) {
        switch change {
        case .upsert(_, let message):
            applyTimelineRecord(message, updateTimeline: true)
        case .remove(let messageIdHex, _):
            removeTimelineRecord(messageIdHex: messageIdHex)
        }
    }

    func loadOlderTimelinePage() async {
        guard hasMoreBefore, !isLoadingOlder,
              let cursor = oldestTimelineCursor(),
              let appState, let accountRef = appState.activeAccountRef
        else { return }

        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let page = try appState.marmot.timelineMessages(
                accountRef: accountRef,
                query: TimelineMessageQueryFfi(
                    groupIdHex: group.groupIdHex,
                    search: nil,
                    before: cursor.timelineAt,
                    beforeMessageId: cursor.messageIdHex,
                    after: nil,
                    afterMessageId: nil,
                    limit: Self.timelinePageLimit
                )
            )
            applyTimelinePage(page, placement: .older)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func applyTimelineRecord(_ record: TimelineMessageRecordFfi, updateTimeline: Bool = false) {
        let appRecord = Self.appMessageRecord(from: record)
        guard !appRecord.messageIdHex.isEmpty else { return }

        messageById[appRecord.messageIdHex] = appRecord
        messageStatusById[appRecord.messageIdHex] = appRecord.direction == "sent" ? .sent : .received
        replyTargetByMessageId[appRecord.messageIdHex] = record.replyToMessageIdHex
        replyPreviewsByMessageId[appRecord.messageIdHex] = record.replyPreview
        projectedReactionSummaries[appRecord.messageIdHex] = record.reactions
        if record.deleted {
            projectedDeletedMessageIds.insert(record.messageIdHex)
        } else {
            projectedDeletedMessageIds.remove(record.messageIdHex)
        }
        reconcilePendingOutgoingMessage(with: appRecord, replyTargetId: record.replyToMessageIdHex)

        if case .streamFinal(let streamId) = MessageSemantics.classify(appRecord) {
            finalizedStreamIds.insert(streamId)
            streamWatchTasks[streamId]?.cancel()
            streamWatchTasks[streamId] = nil
            streamText[streamId] = nil
            transientTimelineItems["msg:stream:\(streamId)"] = nil
            removeTimelineItem(id: "msg:stream:\(streamId)")
        }
        if updateTimeline {
            upsertTimelineItem(TimelineItem.message(appRecord, status: messageStatusById[appRecord.messageIdHex]))
        }
        watchAgentStreamStartIfNeeded(appRecord)
    }

    private func removeTimelineRecord(messageIdHex: String) {
        messageById[messageIdHex] = nil
        messageStatusById[messageIdHex] = nil
        replyTargetByMessageId[messageIdHex] = nil
        replyPreviewsByMessageId[messageIdHex] = nil
        projectedReactionSummaries[messageIdHex] = nil
        projectedDeletedMessageIds.remove(messageIdHex)
        removeTimelineItem(id: "msg:\(messageIdHex)")
    }

    private func oldestTimelineCursor() -> (messageIdHex: String, timelineAt: UInt64)? {
        messageById.values
            .filter { !$0.messageIdHex.isEmpty }
            .min {
                if $0.recordedAt == $1.recordedAt {
                    return $0.messageIdHex < $1.messageIdHex
                }
                return $0.recordedAt < $1.recordedAt
            }
            .map { ($0.messageIdHex, $0.recordedAt) }
    }

    private static func appMessageRecord(from record: TimelineMessageRecordFfi) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: record.messageIdHex,
            direction: record.direction,
            groupIdHex: record.groupIdHex,
            sender: record.sender,
            plaintext: record.plaintext,
            kind: record.kind,
            tags: record.tags,
            recordedAt: record.timelineAt,
            receivedAt: record.receivedAt
        )
    }

    private func rebuildProjectedState(rebuildTimeline shouldRebuildTimeline: Bool = true) {
        rebuildDeletedMessageIds()
        recomputeReactions()
        if shouldRebuildTimeline {
            rebuildTimeline()
        }
    }

    private func rebuildDeletedMessageIds() {
        deletedMessageIds = projectedDeletedMessageIds.union(optimisticDeletedMessageIds)
    }

    private func rebuildTimeline() {
        var next: [TimelineItem] = messageById.values.map { record in
            TimelineItem.message(record, status: messageStatusById[record.messageIdHex])
        }
        next.append(contentsOf: transientTimelineItems.values)
        next.append(contentsOf: systemTimelineItems)
        next.sort(by: Self.timelineItemComesBefore)
        timeline = next
    }

    private func upsertTimelineItem(_ item: TimelineItem) {
        removeTimelineItem(id: item.id)
        let insertionIndex = timelineInsertionIndex(for: item)
        timeline.insert(item, at: insertionIndex)
    }

    private func removeTimelineItem(id: String) {
        timeline.removeAll { $0.id == id }
    }

    private func timelineInsertionIndex(for item: TimelineItem) -> Int {
        var lower = 0
        var upper = timeline.count
        while lower < upper {
            let mid = lower + (upper - lower) / 2
            if Self.timelineItemComesBefore(item, timeline[mid]) {
                upper = mid
            } else {
                lower = mid + 1
            }
        }
        return lower
    }

    private static func timelineItemComesBefore(_ lhs: TimelineItem, _ rhs: TimelineItem) -> Bool {
        if lhs.timestamp == rhs.timestamp {
            return lhs.id < rhs.id
        }
        return lhs.timestamp < rhs.timestamp
    }

    func applyPendingOutgoingMessage(tempId: String, record: AppMessageRecordFfi) {
        let item = TimelineItem.pendingMessage(tempId: tempId, record: record)
        transientTimelineItems[item.id] = item
        upsertTimelineItem(item)
    }

    private func reconcilePendingOutgoingMessage(with record: AppMessageRecordFfi, replyTargetId: String?) {
        guard record.direction == "sent" else { return }
        let projectedReplyTarget = replyTargetId ?? Self.replyTargetMessageId(in: record)
        guard let match = transientTimelineItems.first(where: { _, item in
            Self.pendingOutgoingMessage(item, matches: record, replyTargetId: projectedReplyTarget)
        }) else { return }
        transientTimelineItems[match.key] = nil
        removeTimelineItem(id: match.value.id)
    }

    private static func pendingOutgoingMessage(
        _ item: TimelineItem,
        matches record: AppMessageRecordFfi,
        replyTargetId: String?
    ) -> Bool {
        guard case .message(let pending, let status) = item.kind,
              status == .sending,
              pending.messageIdHex.isEmpty,
              pending.direction == "sent" else {
            return false
        }

        return pending.groupIdHex == record.groupIdHex
            && pending.sender == record.sender
            && pending.plaintext == record.plaintext
            && pending.kind == record.kind
            && replyTargetMessageId(in: pending) == replyTargetId
    }

    private static func replyTargetMessageId(in record: AppMessageRecordFfi) -> String? {
        guard case .reply(let messageId) = MessageSemantics.classify(record) else {
            return nil
        }
        return messageId
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
        streamText[streamId] = Self.cappedStreamText(text)
        upsertStreamBubble(streamId: streamId, sender: sender, status: .received)
        finalizedStreamIds.insert(streamId)
        streamWatchTasks[streamId]?.cancel()
        streamWatchTasks[streamId] = nil
    }

    private func removeStreamBubble(streamId: String) {
        let rowId = "msg:stream:\(streamId)"
        transientTimelineItems[rowId] = nil
        removeTimelineItem(id: rowId)
    }

    func isDeleted(_ messageIdHex: String) -> Bool {
        deletedMessageIds.contains(messageIdHex)
    }

    /// Rebuild the per-target reaction tallies from all reaction messages
    /// (kind-7, emoji in content, target in the `e` tag). A reaction is dropped
    /// when its own event id has been tombstoned by a delete (the un-react path).
    private func recomputeReactions() {
        let me = myAccountId ?? ""
        var byTarget: [String: [String: Set<String>]] = [:]

        for (target, summary) in projectedReactionSummaries {
            for reaction in summary.byEmoji where !reaction.emoji.isEmpty {
                var emojis = byTarget[target] ?? [:]
                emojis[reaction.emoji] = Set(reaction.senders)
                byTarget[target] = emojis
            }
        }

        for removal in optimisticReactionRemovals {
            guard var emojis = byTarget[removal.targetMessageIdHex],
                  var senders = emojis[removal.emoji]
            else { continue }
            senders.remove(removal.sender)
            emojis[removal.emoji] = senders
            byTarget[removal.targetMessageIdHex] = emojis
        }

        let ordered: [AppMessageRecordFfi] = reactionRecords.values
            .sorted { $0.recordedAt < $1.recordedAt }
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
        let item = TimelineItem.systemEvent(id: UUID().uuidString, event: event, timestamp: now)
        systemTimelineItems.append(item)
        upsertTimelineItem(item)
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
        applyPendingOutgoingMessage(tempId: tempId, record: optimistic)
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
        if !realId.isEmpty {
            if messageById[realId] == nil {
                messageById[realId] = confirmed
            }
            messageStatusById[realId] = .sent
        }
        let rowId = "msg:\(realId.isEmpty ? tempId : realId)"
        transientTimelineItems["msg:\(tempId)"] = nil
        removeTimelineItem(id: "msg:\(tempId)")
        if realId.isEmpty {
            let item = TimelineItem(
                id: rowId,
                kind: .message(record: confirmed, status: .sent),
                timestamp: confirmed.recordedAt
            )
            transientTimelineItems[rowId] = item
            upsertTimelineItem(item)
        } else {
            upsertTimelineItem(TimelineItem.message(confirmed, status: .sent))
        }
    }

    private func markFailed(tempId: String) {
        let rowId = "msg:\(tempId)"
        guard let item = transientTimelineItems[rowId],
              case .message(let record, _) = item.kind else { return }
        let failedItem = TimelineItem(
            id: "msg:\(tempId)",
            kind: .message(record: record, status: .failed),
            timestamp: record.recordedAt
        )
        transientTimelineItems[rowId] = failedItem
        upsertTimelineItem(failedItem)
    }

    // MARK: - Reactions

    /// Tombstone a message we are allowed to delete. Optimistically marks it
    /// deleted, then publishes the delete payload (reverting on failure).
    func deleteMessage(_ message: AppMessageRecordFfi) async {
        guard let appState, let accountRef = appState.activeAccountRef,
              !message.messageIdHex.isEmpty,
              Self.canDeleteMessage(message, myAccountId: myAccountId, isSelfAdmin: isSelfAdmin)
        else { return }
        optimisticDeletedMessageIds.insert(message.messageIdHex)
        rebuildDeletedMessageIds()
        do {
            _ = try await appState.marmot.deleteMessage(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex,
                targetMessageId: message.messageIdHex
            )
            Haptics.warning()
        } catch {
            optimisticDeletedMessageIds.remove(message.messageIdHex)
            rebuildDeletedMessageIds()
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
            let insecureLocal = AgentStreamSecurity.insecureLocalEnabled(
                developerMode: appState.developerMode
            )
            let subscription = try await appState.marmot.watchAgentTextStream(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex,
                streamIdHex: streamIdHex,
                serverCertDer: nil,
                // Release builds always pass false here regardless of the
                // developer-mode toggle, so a Settings switch can't disable
                // TLS verification in production. See AgentStreamSecurity.
                insecureLocal: insecureLocal
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
            appendStreamChunk(text, to: streamId)
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

    private func appendStreamChunk(_ text: String, to streamId: String) {
        var current = streamText[streamId] ?? ""
        let remaining = ProfileSanitizer.maxMessageLength - current.count
        guard remaining > 0 else { return }
        current.append(contentsOf: text.prefix(remaining))
        streamText[streamId] = current
    }

    private static func cappedStreamText(_ text: String) -> String {
        if text.count <= ProfileSanitizer.maxMessageLength {
            return text
        }
        return String(text.prefix(ProfileSanitizer.maxMessageLength))
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
            let item = TimelineItem(
                id: rowId,
                kind: .message(record: record, status: status),
                timestamp: timestamp
            )
            transientTimelineItems[rowId] = item
            upsertTimelineItem(item)
        } else {
            let item = TimelineItem(
                id: rowId,
                kind: .message(record: record, status: status),
                timestamp: now
            )
            transientTimelineItems[rowId] = item
            upsertTimelineItem(item)
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
        var removal: ReactionRemoval?

        if alreadyMine {
            removal = ReactionRemoval(
                targetMessageIdHex: message.messageIdHex,
                emoji: emoji,
                sender: me
            )
            if let removal {
                optimisticReactionRemovals.insert(removal)
            }
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
            if let removal { optimisticReactionRemovals.remove(removal) }
            for (key, record) in removedRecords { reactionRecords[key] = record }
            recomputeReactions()
            Haptics.error()
            appState.present(.error(L10n.string("Reaction failed"), message: error.localizedDescription))
        }
    }
}

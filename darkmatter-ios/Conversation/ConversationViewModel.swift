import Foundation
import Observation
import MarmotKit
import os

enum AgentStreamWatchAdmission {
    static func canStart(
        streamIdHex: String?,
        activeStreamIds: Set<String>,
        latestStreamWatchInFlight: Bool
    ) -> Bool {
        if let streamIdHex {
            return !activeStreamIds.contains(streamIdHex)
        }
        return !latestStreamWatchInFlight
    }
}

struct MediaDownloadInFlightKey: Hashable {
    let version: String
    let plaintextSha256: String
    let ciphertextSha256: String
    let nonceHex: String

    init(reference: MediaAttachmentReferenceFfi) {
        self.version = reference.version
        self.plaintextSha256 = reference.plaintextSha256.lowercased()
        self.ciphertextSha256 = reference.ciphertextSha256.lowercased()
        self.nonceHex = reference.nonceHex.lowercased()
    }
}

@MainActor
final class MediaDownloadInFlightStore {
    private var tasks: [MediaDownloadInFlightKey: Task<Data, Error>] = [:]

    func data(
        for key: MediaDownloadInFlightKey,
        operation: @escaping @MainActor () async throws -> Data
    ) async throws -> Data {
        if let task = tasks[key] {
            return try await task.value
        }
        let task = Task { @MainActor in
            try await operation()
        }
        tasks[key] = task
        do {
            let data = try await task.value
            tasks[key] = nil
            return data
        } catch {
            tasks[key] = nil
            throw error
        }
    }
}

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
    private(set) var groupMlsRefreshGeneration: UInt64 = 0
    private(set) var managementState: GroupManagementStateFfi?
    /// targetMessageId -> emoji tallies, derived from materialized timeline rows
    /// plus local optimistic reaction edits.
    private(set) var reactions: [String: [ReactionTally]] = [:]
    /// Message ids tombstoned by the timeline projection or local optimistic deletes.
    private(set) var deletedMessageIds: Set<String> = []
    /// Coarse invalidation token for projection data read through methods.
    private(set) var timelineProjectionGeneration = 0
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
    private var readMarkTask: Task<Void, Never>?
    private var mediaRefreshTask: Task<Void, Never>?

    private static let timelinePageLimit: UInt32 = 50
    private static let liveSubscriptionInitialRetryDelayNanoseconds: UInt64 = 500_000_000
    private static let liveSubscriptionMaximumRetryDelayNanoseconds: UInt64 = 8_000_000_000
    private static let readMarkCoalescingDelayNanoseconds: UInt64 = 100_000_000
    static let maxSystemTimelineItems = 64

    /// Renderable timeline messages we've loaded by id.
    @ObservationIgnored private var messageById: [String: AppMessageRecordFfi] = [:]
    @ObservationIgnored private var messageStatusById: [String: MessageStatus] = [:]
    @ObservationIgnored private var replyTargetByMessageId: [String: String] = [:]
    @ObservationIgnored private var replyPreviewsByMessageId: [String: TimelineReplyPreviewFfi] = [:]
    @ObservationIgnored private var projectedReactionSummaries: [String: TimelineReactionSummaryFfi] = [:]
    @ObservationIgnored private var markdownDisplayProjectionsByRowId: [String: MessageMarkdownDisplayProjection] = [:]
    @ObservationIgnored private var projectedDeletedMessageIds: Set<String> = []
    @ObservationIgnored private var optimisticDeletedMessageIds: Set<String> = []
    private var loadedOlderTimelinePages = false
    @ObservationIgnored private var systemTimelineItems: [TimelineItem] = []
    @ObservationIgnored private var transientTimelineItems: [String: TimelineItem] = [:]
    @ObservationIgnored private var pendingMediaByRowId: [String: [MessageMediaAttachment]] = [:]
    @ObservationIgnored private var mediaRecordsByMessageId: [String: [MediaRecordFfi]] = [:]
    @ObservationIgnored private let mediaDownloadInFlight = MediaDownloadInFlightStore()
    /// Optimistic reaction messages by their own temporary id, re-aggregated on change.
    @ObservationIgnored private var reactionRecords: [String: AppMessageRecordFfi] = [:]
    @ObservationIgnored private var optimisticReactionRemovals: Set<ReactionRemoval> = []
    /// Live agent-stream watch tasks, keyed by stream id.
    private var streamWatchTasks: [String: Task<Void, Never>] = [:]
    /// Guards a concurrent "latest" (nil stream id) watch from racing past the
    /// post-await duplicate guard and opening an orphaned subscription (#48).
    private var latestStreamWatchInFlight = false
    /// Accumulated text per live stream, keyed by stream id.
    private var streamText: [String: String] = [:]
    private var streamTextLengthById: [String: Int] = [:]
#if DEBUG
    var streamTextEntryCountForTesting: Int { streamText.count }
    var streamTextLengthEntryCountForTesting: Int { streamTextLengthById.count }
#endif
    /// Streams that received a checkpoint snapshot. Their QUIC `.finished`
    /// text is text-delta-only, so prefer the current preview at close.
    private var streamsWithCheckpointPreview: Set<String> = []
    /// Streams whose final anchor message has arrived. Once finalized, the
    /// anchor's full text is authoritative and late live updates are ignored.
    private var finalizedStreamIds: Set<String> = []
    /// Start-record timestamps for live previews, keyed by stream id.
    private var streamStartedAtById: [String: UInt64] = [:]
    private var streamSenderById: [String: String] = [:]
    private var markedReadMessageIds: Set<String> = []
    private var pendingReadMessageIds: [String] = []
    private var pendingReadMessageIdSet: Set<String> = []
    /// Transient QUIC debug rows keyed by timeline id (streaming debug only).
    @ObservationIgnored private var streamDebugTimelineItems: [String: TimelineItem] = [:]
    /// Monotonic insert order for QUIC debug rows; zero-padded in ids so
    /// same-second ties sort correctly.
    private var streamDebugEventSequence: UInt64 = 0

    private var streamingDebugEnabled: Bool {
        appState?.streamingDebugEnabled == true
    }

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

    private struct GroupMlsRefreshIdentity: Equatable {
        let groupIdHex: String
        let admins: [String]
        let memberIds: [String]
        let memberAdminStates: [GroupMemberAdminIdentity]
    }

    private struct GroupMemberAdminIdentity: Equatable {
        let memberIdHex: String
        let isAdmin: Bool
    }

    private var groupMlsRefreshIdentity: GroupMlsRefreshIdentity {
        GroupMlsRefreshIdentity(
            groupIdHex: group.groupIdHex,
            admins: group.admins,
            memberIds: members.map(\.memberIdHex),
            memberAdminStates: groupMemberDetails.map {
                GroupMemberAdminIdentity(memberIdHex: $0.memberIdHex, isAdmin: $0.isAdmin)
            }
        )
    }

    private func applyGroupMlsTrackedChanges(_ update: () -> Void) {
        let previousIdentity = groupMlsRefreshIdentity
        update()
        bumpGroupMlsRefreshGenerationIfNeeded(previousIdentity: previousIdentity)
    }

    private func bumpGroupMlsRefreshGenerationIfNeeded(previousIdentity: GroupMlsRefreshIdentity) {
        if groupMlsRefreshIdentity != previousIdentity {
            groupMlsRefreshGeneration &+= 1
        }
    }

    private struct AgentTextStreamProjection: Decodable {
        var streamIdHex: String?
        var status: String?

        enum CodingKeys: String, CodingKey {
            case streamIdHex = "stream_id_hex"
            case status
        }
    }

    private enum AgentTextStreamRecordType {
        static let checkpoint: UInt8 = 0x04
        static let abort: UInt8 = 0x05
        static let finalNotice: UInt8 = 0x06
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
        return L10n.plural("%lld members", Int64(memberCount))
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

    var canSendMediaAttachments: Bool {
        group.encryptedMedia.required
            && group.encryptedMedia.mediaFormat == MessageSemantics.encryptedMediaVersion
            && group.encryptedMedia.allowedLocatorKinds.contains("blossom-v1")
    }

    func isAdmin(_ member: AppGroupMemberRecordFfi) -> Bool {
        if let detail = groupMemberDetails.first(where: { $0.memberIdHex == member.memberIdHex }) {
            return detail.isAdmin
        }
        if group.admins.contains(member.memberIdHex) { return true }
        return false
    }

    /// Members eligible for `@` mention autocomplete in the composer.
    func mentionCandidates(for draft: String) -> [ComposerMentionCandidate] {
        guard let appState,
              let session = ComposerMentionQuery.active(in: draft),
              !ComposerMentionQuery.looksLikeCompleteNpub(session.query)
        else { return [] }
        return ComposerMentionQuery.filter(allMentionCandidates(appState: appState), matching: session.query)
    }

    func applyMentionSelection(_ candidate: ComposerMentionCandidate, to draft: inout String) {
        guard let session = ComposerMentionQuery.active(in: draft) else { return }
        draft = ComposerMentionQuery.replacing(session: session, in: draft, with: candidate.npub)
    }

    private func allMentionCandidates(appState: AppState) -> [ComposerMentionCandidate] {
        if !groupMemberDetails.isEmpty {
            return groupMemberDetails
                .filter { !$0.isSelf }
                .map { ComposerMentionCandidate(details: $0, appState: appState) }
        }
        return members.compactMap { ComposerMentionCandidate(member: $0, appState: appState) }
    }

    func managementAction(for memberIdHex: String) -> GroupMemberActionStateFfi? {
        managementState?.memberActions.first { $0.memberIdHex == memberIdHex }
    }

    /// Reaction tallies for a target message (empty when none).
    func reactions(for messageIdHex: String) -> [ReactionTally] {
        _ = timelineProjectionGeneration
        return reactions[messageIdHex] ?? []
    }

    func markdownDisplayBlocks(for item: TimelineItem) -> [MarkdownDisplayBlock]? {
        _ = timelineProjectionGeneration
        return markdownDisplayProjectionsByRowId[item.id]?.blocks
    }

    func record(for messageIdHex: String) -> AppMessageRecordFfi? {
        _ = timelineProjectionGeneration
        return messageById[messageIdHex]
    }

    /// The quoted preview (sender name + text) for a reply bubble, if resolvable.
    func replyPreview(for record: AppMessageRecordFfi) -> (name: String, text: String)? {
        _ = timelineProjectionGeneration
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
            let text = ProfileSanitizer.singleLine(
                MessagePreview.body(preview, mentionDisplayName: mentionDisplayNameResolver),
                maxLength: 120
            ) ?? ""
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
        MessagePreview.body(record, mentionDisplayName: mentionDisplayNameResolver)
    }

    private var mentionDisplayNameResolver: MarkdownMentionResolver {
        { [weak appState] entity in
            appState?.mentionDisplayName(for: entity)
        }
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
        readMarkTask?.cancel()
        mediaRefreshTask?.cancel()
        for task in streamWatchTasks.values { task.cancel() }
    }

    func start() async {
        guard let appState, let accountRef = appState.activeAccountRef else { return }
        stopLiveSubscriptions()
        resetOptimisticState()
        error = nil
        if timeline.isEmpty {
            isLoading = true
        }
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
        enqueueReadMark(messageIdHex: record.messageIdHex, accountRef: accountRef)
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

    private func initializeReadState() async {
        guard let appState, let accountRef = appState.activeAccountRef else { return }
        do {
            let client = try appState.currentMarmotClient()
            if let row = try await client.initializeChatReadState(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            ) {
                guard !Task.isCancelled else { return }
                onChatListRowUpdated?(row)
            }
        } catch {
            // Read-state setup is opportunistic; the conversation itself still works.
        }
    }

    private func enqueueReadMark(messageIdHex: String, accountRef: String) {
        guard pendingReadMessageIdSet.insert(messageIdHex).inserted else { return }
        pendingReadMessageIds.append(messageIdHex)
        scheduleReadMarkFlush(accountRef: accountRef)
    }

    private func scheduleReadMarkFlush(accountRef: String) {
        guard readMarkTask == nil else { return }
        readMarkTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.readMarkCoalescingDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.flushPendingReadMarks(accountRef: accountRef)
        }
    }

    private func flushPendingReadMarks(accountRef: String) async {
        readMarkTask = nil
        let messageIds = pendingReadMessageIds
        pendingReadMessageIds = []
        pendingReadMessageIdSet = []
        guard !messageIds.isEmpty else { return }
        guard let appState else {
            markedReadMessageIds.subtract(messageIds)
            return
        }
        guard appState.activeAccountRef == accountRef else {
            markedReadMessageIds.subtract(messageIds)
            return
        }

        do {
            let client = try appState.currentMarmotClient()
            let results = await client.markTimelineMessagesRead(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex,
                messageIdHexes: messageIds
            )
            for result in results where !result.succeeded {
                markedReadMessageIds.remove(result.messageIdHex)
            }
            if let row = results.compactMap(\.row).last {
                onChatListRowUpdated?(row)
            }
        } catch {
            markedReadMessageIds.subtract(messageIds)
        }

        if !pendingReadMessageIds.isEmpty, appState.activeAccountRef == accountRef {
            scheduleReadMarkFlush(accountRef: accountRef)
        }
    }

    private func cancelPendingReadMarks() {
        readMarkTask?.cancel()
        readMarkTask = nil
        if !pendingReadMessageIdSet.isEmpty {
            markedReadMessageIds.subtract(pendingReadMessageIdSet)
        }
        pendingReadMessageIds = []
        pendingReadMessageIdSet = []
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
        cancelPendingReadMarks()
        mediaRefreshTask?.cancel()
        mediaRefreshTask = nil
        for task in streamWatchTasks.values {
            task.cancel()
        }
        streamWatchTasks.removeAll()
    }

    private func resetOptimisticState() {
        let backingChanged = !optimisticDeletedMessageIds.isEmpty ||
            !optimisticReactionRemovals.isEmpty ||
            !reactionRecords.isEmpty ||
            !systemTimelineItems.isEmpty ||
            !pendingMediaByRowId.isEmpty
        optimisticDeletedMessageIds.removeAll()
        optimisticReactionRemovals.removeAll()
        reactionRecords.removeAll()
        systemTimelineItems.removeAll()
        pendingMediaByRowId.removeAll()
        let deletedChanged = rebuildDeletedMessageIds()
        let reactionsChanged = recomputeReactions()
        let timelineChanged = backingChanged ? rebuildTimeline() : false
        let changed = backingChanged || deletedChanged || reactionsChanged || timelineChanged
        if changed {
            noteTimelineProjectionChanged()
        }
    }

#if DEBUG
    func resetOptimisticStateForTesting() {
        resetOptimisticState()
    }
#endif

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
                    self?.isLoading = false
                    for await update in SubscriptionDriver.timelineMessageUpdates(timelineSub) {
                        guard !Task.isCancelled else { return }
                        retryDelay = Self.liveSubscriptionInitialRetryDelayNanoseconds
                        self?.applyTimelineSubscriptionUpdate(update)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.isLoading = false
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
                        self?.applyGroupRecord(initial)
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
                let next = try await appState.marmot.groupMembers(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex
                )
                self.applyGroupMlsTrackedChanges {
                    self.members = next
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func startDeferredReadState() {
        readStateTask = Task { [weak self] in
            await self?.initializeReadState()
        }
    }

    private func watchAgentStreamStartIfNeeded(_ record: AppMessageRecordFfi, trigger: TimelineUpdateTriggerFfi?) {
        guard let streamIdHex = Self.agentStreamStartIdToWatch(
            from: record,
            finalizedStreamIds: finalizedStreamIds,
            trigger: trigger
        ) else { return }
        Task { [weak self] in
            await self?.startWatching(
                sender: record.sender,
                streamIdHex: streamIdHex,
                startedAt: record.recordedAt
            )
        }
    }

    static func agentStreamStartIdToWatch(
        from record: AppMessageRecordFfi,
        finalizedStreamIds: Set<String>,
        trigger: TimelineUpdateTriggerFfi?
    ) -> String? {
        guard trigger == .agentStreamStarted,
              case .agentStreamStart(let start) = MessageSemantics.classify(record),
              let streamIdHex = MessageSemantics.normalizedStreamId(start.streamId),
              !finalizedStreamIds.contains(streamIdHex)
        else { return nil }
        return streamIdHex
    }

    func applyTimelinePage(_ page: TimelinePageFfi, placement: TimelinePagePlacement) {
        recordFinalizedStreams(in: page.messages)
        var projectionChanged = false
        for record in page.messages {
            projectionChanged = applyTimelineRecord(record) || projectionChanged
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
        rebuildProjectedState(projectionChanged: projectionChanged)
        isLoading = false
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
        var projectionChanged = false
        if update.changes.isEmpty {
            recordFinalizedStreams(in: update.messages)
            for record in update.messages {
                projectionChanged = applyTimelineRecord(
                    record,
                    updateTimeline: update.messages.count == 1
                ) || projectionChanged
            }
            rebuildTimelineAfterUpdate = update.messages.count != 1
        } else {
            recordFinalizedStreams(in: update.changes.compactMap(Self.upsertedMessage))
            let updateTimelineIncrementally = update.changes.count == 1
            for change in update.changes {
                projectionChanged = applyTimelineChange(
                    change,
                    updateTimeline: updateTimelineIncrementally
                ) || projectionChanged
            }
            rebuildTimelineAfterUpdate = !updateTimelineIncrementally
        }
        if let row = update.chatListRow {
            onChatListRowUpdated?(row)
        }
        rebuildProjectedState(
            rebuildTimeline: rebuildTimelineAfterUpdate,
            projectionChanged: projectionChanged
        )
    }

    @discardableResult
    private func applyTimelineChange(_ change: TimelineMessageChangeFfi, updateTimeline: Bool) -> Bool {
        switch change {
        case .upsert(let trigger, let message):
            return applyTimelineRecord(message, updateTimeline: updateTimeline, trigger: trigger)
        case .remove(let messageIdHex, _):
            return removeTimelineRecord(messageIdHex: messageIdHex, updateTimeline: updateTimeline)
        }
    }

    /// Reloads the newest timeline page from Marmot. Group system rows (kind
    /// 1210) are synthesized locally when commits are processed, so a live
    /// subscription update can race with group-state refresh — especially after
    /// catch-up on a second device/simulator.
    func refreshTimelineTail() async {
        guard let appState, let accountRef = appState.activeAccountRef else { return }
        do {
            let client = try appState.currentMarmotClient()
            let page = try await client.timelineMessages(
                accountRef: accountRef,
                query: TimelineMessageQueryFfi(
                    groupIdHex: group.groupIdHex,
                    search: nil,
                    before: nil,
                    beforeMessageId: nil,
                    after: nil,
                    afterMessageId: nil,
                    limit: Self.timelinePageLimit
                )
            )
            guard !Task.isCancelled else { return }
            applyTimelinePage(page, placement: .tail)
        } catch {
            // Timeline subscription remains the primary live path.
        }
    }

    private func scheduleTimelineTailRefresh() {
        Task { await refreshTimelineTail() }
    }

    func loadOlderTimelinePage() async {
        guard hasMoreBefore, !isLoadingOlder,
              let cursor = oldestTimelineCursor(),
              let appState, let accountRef = appState.activeAccountRef
        else { return }

        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let client = try appState.currentMarmotClient()
            let page = try await client.timelineMessages(
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
            guard !Task.isCancelled else { return }
            applyTimelinePage(page, placement: .older)
        } catch {
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    private func applyTimelineRecord(
        _ record: TimelineMessageRecordFfi,
        updateTimeline: Bool = false,
        trigger: TimelineUpdateTriggerFfi? = nil
    ) -> Bool {
        var projectionChanged = false
        let appRecord = Self.appMessageRecord(from: record)
        guard !appRecord.messageIdHex.isEmpty else { return false }
        let semantics = MessageSemantics.classify(appRecord)
        if case .media = semantics {
            scheduleMediaRecordsRefresh()
        }

        projectionChanged = true
        messageById[appRecord.messageIdHex] = appRecord
        messageStatusById[appRecord.messageIdHex] = appRecord.direction == "sent" ? .sent : .received
        replyTargetByMessageId[appRecord.messageIdHex] = record.replyToMessageIdHex
        replyPreviewsByMessageId[appRecord.messageIdHex] = record.replyPreview
        projectedReactionSummaries[appRecord.messageIdHex] = record.reactions
        reactionRecords = Self.prunedConfirmedOptimisticReactions(
            reactionRecords,
            target: appRecord.messageIdHex,
            summary: record.reactions,
            me: myAccountId ?? ""
        )
        if record.deleted {
            projectedDeletedMessageIds.insert(record.messageIdHex)
        } else {
            projectedDeletedMessageIds.remove(record.messageIdHex)
        }
        projectionChanged = reconcilePendingOutgoingMessage(
            with: appRecord,
            replyTargetId: record.replyToMessageIdHex
        ) || projectionChanged

        if let streamId = Self.finalizedStreamId(from: record, appRecord: appRecord) {
            projectionChanged = resolveFinalizedStream(streamId: streamId) || projectionChanged
        }
        if updateTimeline {
            if let item = visibleTimelineItem(
                for: appRecord,
                status: messageStatusById[appRecord.messageIdHex]
            ) {
                projectionChanged = upsertTimelineItem(item) || projectionChanged
            } else {
                projectionChanged = removeTimelineItem(id: "msg:\(appRecord.messageIdHex)") || projectionChanged
            }
        }
        dropMatchingStreamPreviewIfNeeded(for: appRecord, semantics: semantics, trigger: trigger)
        watchAgentStreamStartIfNeeded(appRecord, trigger: trigger)
        return projectionChanged
    }

    @discardableResult
    private func removeTimelineRecord(messageIdHex: String, updateTimeline: Bool = true) -> Bool {
        let existed = messageById[messageIdHex] != nil
        messageById[messageIdHex] = nil
        messageStatusById[messageIdHex] = nil
        replyTargetByMessageId[messageIdHex] = nil
        replyPreviewsByMessageId[messageIdHex] = nil
        projectedReactionSummaries[messageIdHex] = nil
        projectedDeletedMessageIds.remove(messageIdHex)
        let timelineChanged = updateTimeline
            ? removeTimelineItem(id: "msg:\(messageIdHex)")
            : false
        return existed || timelineChanged
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

    static func appMessageRecord(from record: TimelineMessageRecordFfi) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: record.messageIdHex,
            direction: record.direction,
            groupIdHex: record.groupIdHex,
            sender: record.sender,
            plaintext: record.plaintext,
            contentTokens: record.contentTokens,
            kind: record.kind,
            tags: record.tags,
            recordedAt: record.timelineAt,
            receivedAt: record.receivedAt
        )
    }

    private func rebuildProjectedState(
        rebuildTimeline shouldRebuildTimeline: Bool = true,
        projectionChanged: Bool = false
    ) {
        var changed = projectionChanged
        changed = rebuildDeletedMessageIds() || changed
        changed = recomputeReactions() || changed
        if shouldRebuildTimeline {
            changed = rebuildTimeline() || changed
        }
        if changed {
            noteTimelineProjectionChanged()
        }
    }

    @discardableResult
    private func rebuildDeletedMessageIds() -> Bool {
        let next = projectedDeletedMessageIds.union(optimisticDeletedMessageIds)
        guard deletedMessageIds != next else { return false }
        deletedMessageIds = next
        return true
    }

    @discardableResult
    private func rebuildTimeline() -> Bool {
        var next: [TimelineItem] = messageById.values.compactMap { record in
            visibleTimelineItem(for: record, status: messageStatusById[record.messageIdHex])
        }
        next.append(contentsOf: transientTimelineItems.values)
        next.append(contentsOf: streamDebugTimelineItems.values)
        next.append(contentsOf: systemTimelineItems)
        next.sort(by: Self.timelineItemComesBefore)
        next = Self.normalizedReplyOrdering(
            next,
            replyTargetId: { replyTargetId(for: $0) }
        )
        let markdownChanged = rebuildMarkdownDisplayProjections(
            for: next,
            onlyRowsWithMentions: false
        )
        return assignTimeline(next) || markdownChanged
    }

    func refreshStreamingDebugPresentation() {
        var changed = false
        if !streamingDebugEnabled {
            changed = !streamDebugTimelineItems.isEmpty
            streamDebugTimelineItems.removeAll()
            streamDebugEventSequence = 0
        }
        changed = rebuildTimeline() || changed
        if changed {
            noteTimelineProjectionChanged()
        }
    }

    func refreshProfileDependentTimelineProjections() {
        if rebuildMarkdownDisplayProjections(for: timeline, onlyRowsWithMentions: true) {
            noteTimelineProjectionChanged()
        }
    }

    private func visibleTimelineItem(
        for record: AppMessageRecordFfi,
        status: MessageStatus?
    ) -> TimelineItem? {
        switch MessageSemantics.classify(record) {
        case .chat, .reply, .media, .streamFinal:
            return TimelineItem.message(record, status: status)
        case .agentActivity, .agentOperation:
            guard AgentEventPresentation.display(for: record) != nil else { return nil }
            return TimelineItem.message(record, status: status)
        case .groupSystem:
            guard GroupSystemEventPresentation.isDisplayable(record) else { return nil }
            return TimelineItem.message(record, status: status)
        case .reaction, .delete, .agentStreamStart, .unknown:
            guard streamingDebugEnabled else { return nil }
            return TimelineItem.message(record, status: status)
        }
    }

    @discardableResult
    private func upsertTimelineItem(_ item: TimelineItem) -> Bool {
        var next = timeline.filter { $0.id != item.id }
        let insertionIndex = timelineInsertionIndex(for: item, in: next)
        next.insert(item, at: insertionIndex)
        next = Self.normalizedReplyOrdering(
            next,
            replyTargetId: { replyTargetId(for: $0) }
        )
        let markdownChanged = updateMarkdownDisplayProjection(for: item)
        return assignTimeline(next) || markdownChanged
    }

    @discardableResult
    private func removeTimelineItem(id: String) -> Bool {
        let next = timeline.filter { $0.id != id }
        let markdownChanged = removeMarkdownDisplayProjection(rowId: id)
        return assignTimeline(next) || markdownChanged
    }

    private func assignTimeline(_ next: [TimelineItem]) -> Bool {
        guard timeline != next else { return false }
        timeline = next
        return true
    }

    private func noteTimelineProjectionChanged() {
        timelineProjectionGeneration += 1
    }

    @discardableResult
    private func updateMarkdownDisplayProjection(for item: TimelineItem) -> Bool {
        guard case .message(let record, _) = item.kind else {
            return removeMarkdownDisplayProjection(rowId: item.id)
        }
        guard usesMessageBubbleMarkdownProjection(for: record) else {
            return removeMarkdownDisplayProjection(rowId: item.id)
        }
        let next = MessageMarkdownDisplayProjection.build(
            for: record,
            mentionDisplayName: mentionDisplayNameResolver
        )
        if next.blocks == nil, next.mentionedAccountIds.isEmpty {
            return removeMarkdownDisplayProjection(rowId: item.id)
        }
        guard markdownDisplayProjectionsByRowId[item.id] != next else { return false }
        markdownDisplayProjectionsByRowId[item.id] = next
        return true
    }

    @discardableResult
    private func removeMarkdownDisplayProjection(rowId: String) -> Bool {
        markdownDisplayProjectionsByRowId.removeValue(forKey: rowId) != nil
    }

    @discardableResult
    private func rebuildMarkdownDisplayProjections(
        for items: [TimelineItem],
        onlyRowsWithMentions: Bool
    ) -> Bool {
        var changed = false
        var activeMessageRowIds = Set<String>()
        for item in items {
            guard case .message = item.kind else { continue }
            activeMessageRowIds.insert(item.id)
            if onlyRowsWithMentions,
               markdownDisplayProjectionsByRowId[item.id]?.mentionedAccountIds.isEmpty != false {
                continue
            }
            changed = updateMarkdownDisplayProjection(for: item) || changed
        }
        if !onlyRowsWithMentions {
            for rowId in Array(markdownDisplayProjectionsByRowId.keys) where !activeMessageRowIds.contains(rowId) {
                markdownDisplayProjectionsByRowId[rowId] = nil
                changed = true
            }
        }
        return changed
    }

    private func usesMessageBubbleMarkdownProjection(for record: AppMessageRecordFfi) -> Bool {
        if GroupSystemEventPresentation.isDisplayable(record) {
            return false
        }
        if AgentEventPresentation.display(for: record) != nil {
            return false
        }
        return true
    }

    private func timelineInsertionIndex(for item: TimelineItem, in items: [TimelineItem]) -> Int {
        var lower = 0
        var upper = items.count
        while lower < upper {
            let mid = lower + (upper - lower) / 2
            if Self.timelineItemComesBefore(item, items[mid]) {
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

    @discardableResult
    private func normalizeReplyOrdering() -> Bool {
        assignTimeline(Self.normalizedReplyOrdering(
            timeline,
            replyTargetId: { replyTargetId(for: $0) }
        ))
    }

    static func normalizedReplyOrdering(
        _ items: [TimelineItem],
        replyTargetId: (AppMessageRecordFfi) -> String?
    ) -> [TimelineItem] {
        var messageIds: Set<String> = []
        for item in items {
            guard let messageId = messageId(in: item) else { continue }
            messageIds.insert(messageId)
        }
        guard !messageIds.isEmpty else { return items }

        var ordered: [TimelineItem] = []
        ordered.reserveCapacity(items.count)
        var emittedMessageIds: Set<String> = []
        var deferredRepliesByParentId: [String: [TimelineItem]] = [:]

        func append(_ item: TimelineItem) {
            ordered.append(item)
            guard let messageId = Self.messageId(in: item) else { return }
            emittedMessageIds.insert(messageId)

            let deferredReplies = deferredRepliesByParentId.removeValue(forKey: messageId) ?? []
            for deferred in deferredReplies {
                guard let deferredId = Self.messageId(in: deferred),
                      !emittedMessageIds.contains(deferredId)
                else { continue }
                append(deferred)
            }
        }

        for item in items {
            guard case .message(let record, _) = item.kind,
                  let childId = Self.messageId(in: item),
                  let parentId = replyTargetId(record),
                  parentId != childId,
                  messageIds.contains(parentId),
                  !emittedMessageIds.contains(parentId)
            else {
                append(item)
                continue
            }

            deferredRepliesByParentId[parentId, default: []].append(item)
        }

        if !deferredRepliesByParentId.isEmpty {
            for item in items {
                guard let messageId = Self.messageId(in: item),
                      !emittedMessageIds.contains(messageId)
                else { continue }
                append(item)
            }
        }

        return ordered
    }

    private static func messageId(in item: TimelineItem) -> String? {
        guard case .message(let record, _) = item.kind,
              !record.messageIdHex.isEmpty
        else { return nil }
        return record.messageIdHex
    }

    private func replyTargetId(for record: AppMessageRecordFfi) -> String? {
        replyTargetByMessageId[record.messageIdHex] ?? Self.replyTargetMessageId(in: record)
    }

    func applyPendingOutgoingMessage(tempId: String, record: AppMessageRecordFfi) {
        let item = TimelineItem.pendingMessage(tempId: tempId, record: record)
        transientTimelineItems[item.id] = item
        let changed = upsertTimelineItem(item)
        if changed {
            noteTimelineProjectionChanged()
        }
    }

    func mediaItems(for item: TimelineItem) -> [MessageMediaAttachment] {
        _ = timelineProjectionGeneration
        if let pending = pendingMediaByRowId[item.id] {
            return pending
        }
        guard case .message(let record, _) = item.kind else {
            return []
        }
        return mediaItems(for: record, ownerId: item.id)
    }

    func mediaItems(for record: AppMessageRecordFfi) -> [MessageMediaAttachment] {
        _ = timelineProjectionGeneration
        return mediaItems(for: record, ownerId: record.messageIdHex)
    }

    private func mediaItems(for record: AppMessageRecordFfi, ownerId: String) -> [MessageMediaAttachment] {
        if let records = mediaRecordsByMessageId[record.messageIdHex], !records.isEmpty {
            let references = records
                .sorted { $0.attachmentIndex < $1.attachmentIndex }
                .map(\.reference)
            return MessageMediaAttachment.displayItems(from: references, ownerId: ownerId)
        }
        guard case .media(let references) = MessageSemantics.classify(record) else {
            return []
        }
        return MessageMediaAttachment.displayItems(from: references, ownerId: ownerId)
    }

    func data(for media: MessageMediaAttachment) async throws -> Data {
        if let localData = media.localData {
            return localData
        }
        guard let reference = media.reference else {
            throw MediaDataError.missingReference
        }
        if let cached = MessageMediaCache.cachedData(for: reference) {
            return cached
        }
        guard let appState, let accountRef = appState.activeAccountRef else {
            throw MediaDataError.missingAccount
        }
        let downloadableReference = await downloadableMediaReference(for: reference)
        if let cached = MessageMediaCache.cachedData(for: downloadableReference) {
            return cached
        }
        let groupIdHex = group.groupIdHex
        let marmot = appState.marmot
        return try await mediaDownloadInFlight.data(
            for: MediaDownloadInFlightKey(reference: downloadableReference)
        ) {
            let result = try await marmot.downloadMedia(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                reference: downloadableReference
            )
            MessageMediaCache.store(result.plaintext, for: downloadableReference)
            return result.plaintext
        }
    }

    private func downloadableMediaReference(for reference: MediaAttachmentReferenceFfi) async -> MediaAttachmentReferenceFfi {
        guard reference.sourceEpoch == 0 else { return reference }
        if let mediaRecordReference = mediaRecordReference(matching: reference) {
            return mediaRecordReference
        }
        await refreshMediaRecords()
        return mediaRecordReference(matching: reference) ?? reference
    }

    private func mediaRecordReference(matching reference: MediaAttachmentReferenceFfi) -> MediaAttachmentReferenceFfi? {
        for records in mediaRecordsByMessageId.values {
            for record in records where Self.sameMediaAttachment(record.reference, reference) {
                return record.reference
            }
        }
        return nil
    }

    static func sameMediaAttachment(
        _ lhs: MediaAttachmentReferenceFfi,
        _ rhs: MediaAttachmentReferenceFfi
    ) -> Bool {
        lhs.version == rhs.version
            && lhs.plaintextSha256.lowercased() == rhs.plaintextSha256.lowercased()
            && lhs.ciphertextSha256.lowercased() == rhs.ciphertextSha256.lowercased()
            && lhs.nonceHex.lowercased() == rhs.nonceHex.lowercased()
    }

    private enum MediaDataError: LocalizedError {
        case missingReference
        case missingAccount

        var errorDescription: String? {
            switch self {
            case .missingReference:
                return L10n.string("This attachment is not ready yet.")
            case .missingAccount:
                return L10n.string("No active account.")
            }
        }
    }

    private func scheduleMediaRecordsRefresh() {
        mediaRefreshTask?.cancel()
        mediaRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            await self?.refreshMediaRecords()
        }
    }

    func refreshMediaRecords(limit: UInt32 = 500) async {
        guard let appState, let accountRef = appState.activeAccountRef else { return }
        do {
            let client = try appState.currentMarmotClient()
            let records = try await client.listMedia(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex,
                limit: limit
            )
            guard !Task.isCancelled else { return }
            let next = Dictionary(grouping: records, by: \.messageIdHex)
            guard mediaRecordsByMessageId != next else { return }
            mediaRecordsByMessageId = next
            noteTimelineProjectionChanged()
        } catch {
            // Media rows are a display accelerator for decrypt/download. The
            // timeline remains usable and future updates retry the refresh.
        }
    }

    @discardableResult
    private func reconcilePendingOutgoingMessage(with record: AppMessageRecordFfi, replyTargetId: String?) -> Bool {
        guard record.direction == "sent" else { return false }
        let projectedReplyTarget = replyTargetId ?? Self.replyTargetMessageId(in: record)
        let matchingPendingMessages = transientTimelineItems.filter { _, item in
            Self.pendingOutgoingMessage(item, matches: record, replyTargetId: projectedReplyTarget)
        }
        guard let match = matchingPendingMessages.min(by: { lhs, rhs in
            Self.pendingOutgoingMessage(lhs.value, isCloserTo: record, than: rhs.value)
        }) else { return false }
        transientTimelineItems[match.key] = nil
        pendingMediaByRowId[match.key] = nil
        _ = removeTimelineItem(id: match.value.id)
        return true
    }

    private static func pendingOutgoingMessage(
        _ item: TimelineItem,
        matches record: AppMessageRecordFfi,
        replyTargetId: String?
    ) -> Bool {
        guard case .message(let pending, let status) = item.kind,
              status == .sending || status == .sent,
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

    private static func pendingOutgoingMessage(
        _ lhs: TimelineItem,
        isCloserTo record: AppMessageRecordFfi,
        than rhs: TimelineItem
    ) -> Bool {
        let lhsDistance = pendingOutgoingRecordedAtDistance(lhs, to: record.recordedAt)
        let rhsDistance = pendingOutgoingRecordedAtDistance(rhs, to: record.recordedAt)
        if lhsDistance == rhsDistance {
            return lhs.id < rhs.id
        }
        return lhsDistance < rhsDistance
    }

    private static func pendingOutgoingRecordedAtDistance(_ item: TimelineItem, to recordedAt: UInt64) -> UInt64 {
        guard case .message(let pending, _) = item.kind else {
            return .max
        }
        return pending.recordedAt > recordedAt
            ? pending.recordedAt - recordedAt
            : recordedAt - pending.recordedAt
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
        clearStreamPreviewText(streamId: streamId)
        streamsWithCheckpointPreview.remove(streamId)
        streamStartedAtById[streamId] = nil
        streamSenderById[streamId] = nil
        if removeStreamBubble(streamId: streamId) {
            noteTimelineProjectionChanged()
        }
    }

    /// Promote the transient live preview into a permanent received bubble
    /// carrying the final transcript. The Final MLS anchor is authoritative; the
    /// QUIC `.finished` transcript is a provisional fill if it lands first. Both
    /// key the same `msg:stream:<id>` row, so whichever arrives later wins.
    private func finalizeStreamBubble(streamId: String, sender: String, text: String) {
        replaceStreamPreviewText(text, to: streamId)
        guard hasStreamPreviewText(streamId: streamId) else {
            endStream(streamId: streamId)
            return
        }
        streamSenderById[streamId] = sender
        upsertStreamBubble(streamId: streamId, sender: sender, status: .received)
        finalizedStreamIds.insert(streamId)
        streamWatchTasks[streamId]?.cancel()
        streamWatchTasks[streamId] = nil
        streamsWithCheckpointPreview.remove(streamId)
        streamStartedAtById[streamId] = nil
        streamSenderById[streamId] = nil
        clearStreamPreviewText(streamId: streamId)
    }

    @discardableResult
    private func resolveFinalizedStream(streamId: String) -> Bool {
        finalizedStreamIds.insert(streamId)
        streamWatchTasks[streamId]?.cancel()
        streamWatchTasks[streamId] = nil
        clearStreamPreviewText(streamId: streamId)
        streamsWithCheckpointPreview.remove(streamId)
        streamStartedAtById[streamId] = nil
        streamSenderById[streamId] = nil
        return removeStreamBubble(streamId: streamId)
    }

    @discardableResult
    private func removeStreamBubble(streamId: String) -> Bool {
        let rowId = "msg:stream:\(streamId)"
        let backingChanged = transientTimelineItems.removeValue(forKey: rowId) != nil
        return removeTimelineItem(id: rowId) || backingChanged
    }

    func isDeleted(_ messageIdHex: String) -> Bool {
        _ = timelineProjectionGeneration
        return deletedMessageIds.contains(messageIdHex)
    }

    /// Rebuild the per-target reaction tallies from all reaction messages
    /// (kind-7, emoji in content, target in the `e` tag). A reaction is dropped
    /// when its own event id has been tombstoned by a delete (the un-react path).
    @discardableResult
    private func recomputeReactions() -> Bool {
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
        guard reactions != result else { return false }
        reactions = result
        return true
    }

    /// Drop optimistic reaction placeholders that the server projection has now
    /// confirmed (same target + emoji + sender). Without this, `reactionRecords`
    /// keeps every optimistic entry for the life of the conversation even after
    /// the authoritative projection arrives (#47). The displayed tally is
    /// unaffected because the confirmed reaction still comes from the summary.
    nonisolated static func prunedConfirmedOptimisticReactions(
        _ records: [String: AppMessageRecordFfi],
        target: String,
        summary: TimelineReactionSummaryFfi,
        me: String
    ) -> [String: AppMessageRecordFfi] {
        guard !me.isEmpty else { return records }
        let confirmedEmoji = Set(
            summary.byEmoji
                .filter { $0.senders.contains(me) }
                .map(\.emoji)
        )
        guard !confirmedEmoji.isEmpty else { return records }
        return records.filter { _, record in
            guard record.sender == me,
                  confirmedEmoji.contains(record.plaintext),
                  case .reaction(let recordTarget) = MessageSemantics.classify(record),
                  recordTarget == target
            else { return true }
            return false
        }
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
            contentTokens: r.message.contentTokens,
            kind: r.message.kind,
            tags: r.message.tags,
            recordedAt: r.message.recordedAt > 0 ? r.message.recordedAt : now,
            receivedAt: now
        )
    }

    private func applyGroupUpdate(_ record: AppGroupRecordFfi) async {
        let previousName = group.name
        let wasArchived = group.archived
        let previousAdmins = Set(group.admins)
        applyGroupMlsTrackedChanges {
            group = record
        }

        if Set(record.admins) != previousAdmins {
            await refreshTimelineTail()
        }

        if !previousName.isEmpty && previousName != record.name {
            if let name = ProfileSanitizer.groupName(record.name) {
                appendSystemEvent(.groupRenamed(name))
            }
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
        applyGroupMlsTrackedChanges {
            group = record
        }
    }

    func applyGroupMutation(_ result: GroupMutationResultFfi) {
        applyGroupDetails(result.details, managementState: result.managementState)
        // Group system rows for our own commits are persisted in Marmot but
        // not yet broadcast on the timeline subscription (see darkmatter
        // remember_published_reports). Reload the tail after every mutation,
        // and don't rely on admin/member diffs — optimistic UI updates them
        // before the mutation returns.
        scheduleTimelineTailRefresh()
    }

    func applyOptimisticAdminStatus(memberIdHex: String, isAdmin: Bool) {
        let previousIdentity = groupMlsRefreshIdentity
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
        bumpGroupMlsRefreshGenerationIfNeeded(previousIdentity: previousIdentity)

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
        let previousAdmins = Set(group.admins)
        let previousMemberIds = members.map(\.memberIdHex)
        let previousIdentity = groupMlsRefreshIdentity
        let nextMembers = details.members.map {
            AppGroupMemberRecordFfi(
                memberIdHex: $0.memberIdHex,
                account: $0.account,
                local: $0.local
            )
        }
        let nextMemberIds = nextMembers.map(\.memberIdHex)
        if announceRosterChanges && nextMemberIds != previousMemberIds {
            appendSystemEvent(.rosterChanged)
            appState?.present(.success(L10n.string("Group membership updated")))
        }
        group = details.group
        groupMemberDetails = details.members
        managementState = state
        members = nextMembers
        bumpGroupMlsRefreshGenerationIfNeeded(previousIdentity: previousIdentity)
        if Set(details.group.admins) != previousAdmins || nextMemberIds != previousMemberIds {
            scheduleTimelineTailRefresh()
        }
    }

    private func appendSystemEvent(_ event: SystemEvent) {
        appendSystemEvent(event, timestamp: UInt64(Date().timeIntervalSince1970))
    }

    private func appendSystemEvent(_ event: SystemEvent, timestamp: UInt64) {
        let item = TimelineItem.systemEvent(id: UUID().uuidString, event: event, timestamp: timestamp)
        let previousItems = systemTimelineItems
        systemTimelineItems = Self.retainedSystemTimelineItems(
            systemTimelineItems,
            appending: item,
            limit: Self.maxSystemTimelineItems
        )

        let retainedIds = Set(systemTimelineItems.map(\.id))
        var changed = false
        for previousItem in previousItems where !retainedIds.contains(previousItem.id) {
            changed = removeTimelineItem(id: previousItem.id) || changed
        }
        if systemTimelineItems.contains(where: { $0.id == item.id }) {
            changed = upsertTimelineItem(item) || changed
        }
        if changed {
            noteTimelineProjectionChanged()
        }
    }

#if DEBUG
    func appendSystemEventForTesting(_ event: SystemEvent, timestamp: UInt64) {
        appendSystemEvent(event, timestamp: timestamp)
    }
#endif

    static func retainedSystemTimelineItems(
        _ current: [TimelineItem],
        appending item: TimelineItem,
        limit: Int = maxSystemTimelineItems
    ) -> [TimelineItem] {
        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else { return [] }

        var next = current
        if next.last?.kind == item.kind {
            next[next.count - 1] = item
        } else {
            next.append(item)
        }
        if next.count > boundedLimit {
            next.removeFirst(next.count - boundedLimit)
        }
        return next
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
            applyGroupMlsTrackedChanges {
                members = next
            }
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

        // Defense-in-depth: clamp to the protocol's max length so an oversized
        // paste can't bypass the composer's cap (#54).
        let outgoing = Self.cappedOutgoingText(trimmed)

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
            plaintext: outgoing,
            contentTokens: appState.marmot.parseMarkdown(text: outgoing),
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
                    text: outgoing
                )
            } else {
                summary = try await appState.marmot.sendText(
                    accountRef: accountRef,
                    groupIdHex: group.groupIdHex,
                    text: outgoing
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

    func sendMedia(_ attachments: [MediaDraftAttachment], caption: String) async {
        guard !attachments.isEmpty,
              canSendMediaAttachments,
              let appState,
              let accountRef = appState.activeAccountRef else { return }

        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoingCaption = trimmedCaption.isEmpty ? "" : Self.cappedOutgoingText(trimmedCaption)
        let captionForRust = outgoingCaption.isEmpty ? nil : outgoingCaption
        let tempId = UUID().uuidString
        let tempRowId = "msg:\(tempId)"
        let now = UInt64(Date().timeIntervalSince1970)
        let captionTokens: MarkdownDocumentFfi = outgoingCaption.isEmpty
            ? .emptyDocument
            : appState.marmot.parseMarkdown(text: outgoingCaption)
        let optimistic = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: group.groupIdHex,
            sender: appState.activeAccount?.accountIdHex ?? "",
            plaintext: outgoingCaption,
            contentTokens: captionTokens,
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: now,
            receivedAt: now
        )
        pendingMediaByRowId[tempRowId] = attachments.map(\.displayItem)
        applyPendingOutgoingMessage(tempId: tempId, record: optimistic)
        replyingTo = nil

        sendInFlight = true
        defer { sendInFlight = false }
        do {
            let result = try await appState.marmot.uploadMedia(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex,
                request: MediaUploadRequestFfi(
                    attachments: attachments.map(\.uploadRequest),
                    caption: captionForRust,
                    send: true,
                    blossomServer: nil
                )
            )
            let references = result.attachments.map(\.reference)
            let confirmed = AppMessageRecordFfi(
                messageIdHex: "",
                direction: "sent",
                groupIdHex: group.groupIdHex,
                sender: optimistic.sender,
                plaintext: outgoingCaption,
                contentTokens: captionTokens,
                kind: MessageSemantics.kindChat,
                tags: references.map(MessageSemantics.imetaTag(for:)),
                recordedAt: now,
                receivedAt: now
            )
            let messageId = result.sent?.messageIds.first
            confirmSent(tempId: tempId, record: confirmed, messageId: messageId)
            if let messageId, !messageId.isEmpty {
                let nextRecords = references.enumerated().map { index, reference in
                    MediaRecordFfi(
                        messageIdHex: messageId,
                        attachmentIndex: UInt32(index),
                        direction: "sent",
                        groupIdHex: group.groupIdHex,
                        sender: optimistic.sender,
                        reference: reference,
                        caption: captionForRust,
                        recordedAt: now,
                        receivedAt: now
                    )
                }
                if mediaRecordsByMessageId[messageId] != nextRecords {
                    mediaRecordsByMessageId[messageId] = nextRecords
                    noteTimelineProjectionChanged()
                }
            }
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

    func confirmSent(tempId: String, record: AppMessageRecordFfi, messageId: String?) {
        var projectionChanged = false
        let realId = messageId ?? ""
        let confirmed = AppMessageRecordFfi(
            messageIdHex: realId,
            direction: "sent",
            groupIdHex: record.groupIdHex,
            sender: record.sender,
            plaintext: record.plaintext,
            contentTokens: record.contentTokens,
            kind: record.kind,
            tags: record.tags,
            recordedAt: record.recordedAt,
            receivedAt: record.receivedAt
        )
        if !realId.isEmpty {
            if messageById[realId] == nil {
                messageById[realId] = confirmed
                projectionChanged = true
            }
            if messageStatusById[realId] != .sent {
                projectionChanged = true
            }
            messageStatusById[realId] = .sent
        }
        let rowId = "msg:\(realId.isEmpty ? tempId : realId)"
        projectionChanged = (transientTimelineItems.removeValue(forKey: "msg:\(tempId)") != nil) || projectionChanged
        projectionChanged = (pendingMediaByRowId.removeValue(forKey: "msg:\(tempId)") != nil) || projectionChanged
        projectionChanged = removeTimelineItem(id: "msg:\(tempId)") || projectionChanged
        if realId.isEmpty {
            let item = TimelineItem(
                id: rowId,
                kind: .message(record: confirmed, status: .sent),
                timestamp: confirmed.recordedAt
            )
            transientTimelineItems[rowId] = item
            projectionChanged = true
            projectionChanged = upsertTimelineItem(item) || projectionChanged
        } else {
            projectionChanged = upsertTimelineItem(TimelineItem.message(confirmed, status: .sent)) || projectionChanged
        }
        if projectionChanged {
            noteTimelineProjectionChanged()
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
        if upsertTimelineItem(failedItem) {
            noteTimelineProjectionChanged()
        }
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
        if rebuildDeletedMessageIds() {
            noteTimelineProjectionChanged()
        }
        do {
            _ = try await appState.marmot.deleteMessage(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex,
                targetMessageId: message.messageIdHex
            )
            Haptics.warning()
        } catch {
            optimisticDeletedMessageIds.remove(message.messageIdHex)
            if rebuildDeletedMessageIds() {
                noteTimelineProjectionChanged()
            }
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
    private func startWatching(sender: String, streamIdHex: String?, startedAt: UInt64? = nil) async {
        guard let appState, let accountRef = appState.activeAccountRef else { return }
        guard AgentStreamWatchAdmission.canStart(
            streamIdHex: streamIdHex,
            activeStreamIds: Set(streamWatchTasks.keys),
            latestStreamWatchInFlight: latestStreamWatchInFlight
        ) else { return }
        if streamIdHex == nil { latestStreamWatchInFlight = true }
        defer { if streamIdHex == nil { latestStreamWatchInFlight = false } }
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
            if finalizedStreamIds.contains(streamId) { return }
            if let startedAt, startedAt > 0 {
                streamStartedAtById[streamId] = startedAt
            }
            resetStreamPreviewText(streamId: streamId)
            streamSenderById[streamId] = sender
            Self.streamLog.info("watch opened: streamId=\(streamId, privacy: .public) developerMode=\(appState.developerMode, privacy: .public); waiting for text preview")
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
            appendStreamDebugEvent(streamId: streamId, eventKind: "chunk", detail: streamDebugTextSummary(text))
            appendStreamChunk(text, to: streamId)
            upsertStreamBubbleIfNeeded(streamId: streamId, sender: sender, status: .streaming)
        case .status(let seq, let status):
            appendStreamDebugEvent(streamId: streamId, eventKind: "status", detail: "seq=\(seq) \(status)")
        case .progress(let seq, let text):
            appendStreamDebugEvent(streamId: streamId, eventKind: "progress", detail: "seq=\(seq) \(streamDebugTextSummary(text))")
        case .record(_, let recordType, let text):
            appendStreamDebugEvent(
                streamId: streamId,
                eventKind: "record(\(recordType))",
                detail: streamDebugTextSummary(text)
            )
            switch recordType {
            case AgentTextStreamRecordType.checkpoint:
                streamsWithCheckpointPreview.insert(streamId)
                replaceStreamPreviewText(text, to: streamId)
                upsertStreamBubbleIfNeeded(streamId: streamId, sender: sender, status: .streaming)
            case AgentTextStreamRecordType.abort:
                endStream(streamId: streamId)
            case AgentTextStreamRecordType.finalNotice:
                break
            default:
                break
            }
        case .finished(let text, let transcriptHashHex, let chunkCount):
            appendStreamDebugEvent(
                streamId: streamId,
                eventKind: "finished",
                detail: "chunks=\(chunkCount) textLen=\(text.count)B hashLen=\(transcriptHashHex.count)"
            )
            // QUIC stream closed. Promote the preview to a permanent bubble using
            // the streamed transcript; the authoritative MLS Final anchor will
            // overwrite the same row if it arrives afterwards.
            Self.streamLog.info("finished: streamId=\(streamId, privacy: .public) chunkCount=\(chunkCount) textLen=\(text.count)B hashLen=\(transcriptHashHex.count) — promoting preview to permanent bubble")
            finalizeStreamBubble(
                streamId: streamId,
                sender: sender,
                text: finishedPreviewText(streamId: streamId, text: text)
            )
        case .failed(let message):
            appendStreamDebugEvent(streamId: streamId, eventKind: "failed", detail: message)
            let previewLength = streamTextLengthById[streamId] ?? streamText[streamId]?.count ?? 0
            Self.streamLog.error("failed: streamId=\(streamId, privacy: .public) gotText=\(previewLength)B reason=\(message, privacy: .public) — dropping live preview")
            endStream(streamId: streamId)
        }
    }

    private func appendStreamDebugEvent(streamId: String, eventKind: String, detail: String) {
        guard streamingDebugEnabled else { return }
        streamDebugEventSequence += 1
        let sequence = streamDebugEventSequence
        let now = UInt64(Date().timeIntervalSince1970)
        let item = TimelineItem.streamDebugEvent(
            id: "dbg:stream:\(streamId):\(now):\(String(format: "%010llu", sequence))",
            streamId: streamId,
            eventKind: eventKind,
            detail: detail,
            timestamp: now
        )
        streamDebugTimelineItems[item.id] = item
        if upsertTimelineItem(item) {
            noteTimelineProjectionChanged()
        }
    }

    private func streamDebugTextSummary(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(empty)" }
        if trimmed.count <= 120 { return trimmed }
        return "\(trimmed.prefix(120))… (\(trimmed.count) chars)"
    }

    private func appendStreamChunk(_ text: String, to streamId: String) {
        let currentLength = streamTextLengthById[streamId] ?? streamText[streamId]?.count ?? 0
        let remaining = ProfileSanitizer.maxMessageLength - currentLength
        guard remaining > 0 else { return }
        let cappedChunk = text.prefix(remaining)
        guard !cappedChunk.isEmpty else { return }
        var current = streamText[streamId] ?? ""
        current.append(contentsOf: cappedChunk)
        streamText[streamId] = current
        streamTextLengthById[streamId] = currentLength + cappedChunk.count
    }

    private func replaceStreamPreviewText(_ text: String, to streamId: String) {
        let capped = Self.cappedStreamText(text)
        streamText[streamId] = capped.text
        streamTextLengthById[streamId] = capped.length
    }

    private func resetStreamPreviewText(streamId: String) {
        streamText[streamId] = ""
        streamTextLengthById[streamId] = 0
    }

    private func clearStreamPreviewText(streamId: String) {
        streamText[streamId] = nil
        streamTextLengthById[streamId] = nil
    }

    private func hasStreamPreviewText(streamId: String) -> Bool {
        guard let text = streamText[streamId] else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func finishedPreviewText(streamId: String, text: String) -> String {
        guard streamsWithCheckpointPreview.contains(streamId),
              let preview = streamText[streamId],
              !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return text
        }
        return preview
    }

    private static func cappedStreamText(_ text: String) -> (text: String, length: Int) {
        let length = text.count
        if length <= ProfileSanitizer.maxMessageLength {
            return (text, length)
        }
        let capped = String(text.prefix(ProfileSanitizer.maxMessageLength))
        return (capped, ProfileSanitizer.maxMessageLength)
    }

    nonisolated static func streamPreviewTimestamp(startedAt: UInt64?, fallback: UInt64) -> UInt64 {
        guard let startedAt, startedAt > 0 else { return fallback }
        return startedAt
    }

    private func streamPreviewTimestamp(for streamId: String) -> UInt64 {
        let now = UInt64(Date().timeIntervalSince1970)
        let timestamp = Self.streamPreviewTimestamp(
            startedAt: streamStartedAtById[streamId],
            fallback: now
        )
        streamStartedAtById[streamId] = timestamp
        return timestamp
    }

    /// Clamp outbound message text to the protocol's max length (#54).
    nonisolated static func cappedOutgoingText(_ text: String) -> String {
        String(text.prefix(ProfileSanitizer.maxMessageLength))
    }

    /// Create or update the synthetic bubble for a live stream (keyed by id).
    private func upsertStreamBubbleIfNeeded(streamId: String, sender: String, status: MessageStatus) {
        guard hasStreamPreviewText(streamId: streamId) else { return }
        upsertStreamBubble(streamId: streamId, sender: sender, status: status)
    }

    private func upsertStreamBubble(streamId: String, sender: String, status: MessageStatus) {
        let rowId = "msg:stream:\(streamId)"
        streamSenderById[streamId] = sender
        let timestamp = streamPreviewTimestamp(for: streamId)
        let record = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "received",
            groupIdHex: group.groupIdHex,
            sender: sender,
            plaintext: streamText[streamId] ?? "",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: timestamp,
            receivedAt: timestamp
        )
        if let idx = timeline.firstIndex(where: { $0.id == rowId }) {
            let timestamp = timeline[idx].timestamp
            let item = TimelineItem(
                id: rowId,
                kind: .message(record: record, status: status),
                timestamp: timestamp
            )
            transientTimelineItems[rowId] = item
            if upsertTimelineItem(item) {
                noteTimelineProjectionChanged()
            }
        } else {
            let item = TimelineItem(
                id: rowId,
                kind: .message(record: record, status: status),
                timestamp: timestamp
            )
            transientTimelineItems[rowId] = item
            if upsertTimelineItem(item) {
                noteTimelineProjectionChanged()
            }
        }
    }

    private func recordFinalizedStreams(in records: [TimelineMessageRecordFfi]) {
        for record in records {
            let appRecord = Self.appMessageRecord(from: record)
            if let streamId = Self.finalizedStreamId(from: record, appRecord: appRecord) {
                finalizedStreamIds.insert(streamId)
            }
        }
    }

    private static func upsertedMessage(from change: TimelineMessageChangeFfi) -> TimelineMessageRecordFfi? {
        if case .upsert(_, let message) = change { return message }
        return nil
    }

    private static func finalizedStreamId(
        from record: TimelineMessageRecordFfi,
        appRecord: AppMessageRecordFfi
    ) -> String? {
        if let projection = agentTextStreamProjection(from: record),
           projection.status == "finalized",
           let streamId = MessageSemantics.normalizedStreamId(projection.streamIdHex) {
            return streamId
        }
        if case .streamFinal(let streamId) = MessageSemantics.classify(appRecord) {
            return streamId
        }
        return nil
    }

    private static func agentTextStreamProjection(from record: TimelineMessageRecordFfi) -> AgentTextStreamProjection? {
        guard let json = record.agentTextStreamJson,
              let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(AgentTextStreamProjection.self, from: data)
    }

    private func dropMatchingStreamPreviewIfNeeded(
        for record: AppMessageRecordFfi,
        semantics: MessageSemantics.Kind,
        trigger: TimelineUpdateTriggerFfi?
    ) {
        guard trigger != nil,
              record.direction == "received"
        else { return }
        switch semantics {
        case .chat, .reply, .media:
            let streamIds = streamSenderById
                .filter { $0.value == record.sender }
                .map(\.key)
            for streamId in streamIds {
                endStream(streamId: streamId)
            }
        case .streamFinal, .reaction, .delete, .agentStreamStart, .agentActivity, .agentOperation, .groupSystem, .unknown:
            return
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
        if recomputeReactions() {
            noteTimelineProjectionChanged()
        }
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
            if recomputeReactions() {
                noteTimelineProjectionChanged()
            }
            Haptics.error()
            appState.present(.error(L10n.string("Reaction failed"), message: error.localizedDescription))
        }
    }
}

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

enum TimelineTailRefreshTaskLifetime {
    static func nextGeneration(after generation: UInt64) -> UInt64 {
        generation &+ 1
    }

    static func shouldClearStoredTask(currentGeneration: UInt64, completedGeneration: UInt64) -> Bool {
        currentGeneration == completedGeneration
    }
}

private struct TimelineTailRefreshRequest {
    let client: MarmotClient
    let accountRef: String
    let groupIdHex: String
}

typealias TimelineTailRefreshOperation = @MainActor () async -> Void

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
    private(set) var hasMoreAfter = false
    private(set) var isLoadingOlder = false
    private(set) var isLoadingNewer = false
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
    private var initialTimelineSnapshotTask: Task<Void, Never>?
    private var groupStateTask: Task<Void, Never>?
    private var groupDetailsTask: Task<Void, Never>?
    private var readStateTask: Task<Void, Never>?
    private var readMarkTask: Task<Void, Never>?
    private var mediaRefreshTask: Task<Void, Never>?
    private var tailRefreshTask: Task<Void, Never>?
    private var tailRefreshGeneration: UInt64 = 0

    private static let timelinePageLimit: UInt32 = 50
    private static let liveSubscriptionInitialRetryDelayNanoseconds: UInt64 = 500_000_000
    private static let liveSubscriptionMaximumRetryDelayNanoseconds: UInt64 = 8_000_000_000
    private static let readMarkCoalescingDelayNanoseconds: UInt64 = 100_000_000
    private static let maxMarkedReadMessageIds = Int(timelinePageLimit) * 4
    nonisolated static let maxSystemTimelineItems = 64

    /// Renderable timeline messages we've loaded by id.
    @ObservationIgnored private var messageById: [String: AppMessageRecordFfi] = [:]
    @ObservationIgnored private var messageStatusById: [String: MessageStatus] = [:]
    @ObservationIgnored private var replyTargetByMessageId: [String: String] = [:]
    @ObservationIgnored private var replyPreviewsByMessageId: [String: TimelineReplyPreviewFfi] = [:]
    @ObservationIgnored private var projectedReactionSummaries: [String: TimelineReactionSummaryFfi] = [:]
    @ObservationIgnored private var markdownDisplayProjectionsByRowId: [String: MessageMarkdownDisplayProjection] = [:]
    @ObservationIgnored private var projectedDeletedMessageIds: Set<String> = []
    @ObservationIgnored private var optimisticDeletedMessageIds: Set<String> = []
    @ObservationIgnored private var timelineSubscription: TimelineMessagesSubscription?
    @ObservationIgnored private var systemTimelineItems: [TimelineItem] = []
    @ObservationIgnored private var transientTimelineItems: [String: TimelineItem] = [:]
    @ObservationIgnored private var pendingMediaByRowId: [String: [MessageMediaAttachment]] = [:]
    @ObservationIgnored private var mediaRecordsByMessageId: [String: [MediaRecordFfi]] = [:]
    @ObservationIgnored private var mediaRecordReferencesByKey: [MediaDownloadInFlightKey: MediaAttachmentReferenceFfi] = [:]
    @ObservationIgnored private let mediaDownloadInFlight = MediaDownloadInFlightStore()
    /// Optimistic reaction messages by their own temporary id, re-aggregated on change.
    @ObservationIgnored private var reactionRecords: [String: AppMessageRecordFfi] = [:]
    @ObservationIgnored private var optimisticReactionRemovals: Set<ReactionRemoval> = []
    /// Cached `@`-mention autocomplete candidates and the generation pair they
    /// were built from. `mentionCandidates(for:)` runs on every composer
    /// keystroke; rebuilding the candidate array (and re-deriving each
    /// candidate's lowercased match fields) per keystroke is avoidable work on
    /// the MainActor typing hot path (see issue #300). The cache is rebuilt only
    /// when the group roster (`groupMlsRefreshGeneration`) or resolved profile
    /// data (`AppState.profileRefreshGeneration`) actually changes.
    @ObservationIgnored private var cachedMentionCandidates: [ComposerMentionCandidate]?
    @ObservationIgnored private var cachedMentionCandidatesKey: MentionCandidateCacheKey?
    /// Live agent-stream watch tasks, keyed by stream id.
    private var streamWatchTasks: [String: Task<Void, Never>] = [:]
    /// Generation token per stream watch. A watch task only clears its own
    /// `streamWatchTasks` entry on natural completion if the stored generation
    /// still matches — mirroring the `NotificationDriver` completion guard so a
    /// re-watch that reused the key isn't torn down by a stale task exit.
    private var streamWatchGenerations: [String: UUID] = [:]
    /// Guards a concurrent "latest" (nil stream id) watch from racing past the
    /// post-await duplicate guard and opening an orphaned subscription (#48).
    private var latestStreamWatchInFlight = false
    /// Accumulated text per live stream, keyed by stream id.
    private var streamText: [String: String] = [:]
    private var streamTextLengthById: [String: Int] = [:]
#if DEBUG
    var streamTextEntryCountForTesting: Int { streamText.count }
    var streamTextLengthEntryCountForTesting: Int { streamTextLengthById.count }
    var scannedFinalizedMessageIdCountForTesting: Int { scannedFinalizedMessageIds.count }
    var finalizedStreamIdCountForTesting: Int { finalizedStreamIds.count }
    var markedReadMessageIdsForTesting: Set<String> { markedReadMessageIds }

    func insertMarkedReadMessageIdsForTesting(_ messageIds: Set<String>) {
        markedReadMessageIds.formUnion(messageIds)
        pruneMarkedReadMessageIds(force: true)
    }

    func insertPendingReadMessageIdsForTesting(_ messageIds: [String]) {
        for messageId in messageIds {
            guard pendingReadMessageIdSet.insert(messageId).inserted else { continue }
            pendingReadMessageIds.append(messageId)
        }
    }
#endif
    /// Streams that received a checkpoint snapshot. Their QUIC `.finished`
    /// text is text-delta-only, so prefer the current preview at close.
    private var streamsWithCheckpointPreview: Set<String> = []
    /// Streams whose final anchor message has arrived. Once finalized, the
    /// anchor's full text is authoritative and late live updates are ignored.
    /// Populated both by scanning loaded anchor records and by live-stream
    /// resolution (endStream/finalizeStreamBubble/resolveFinalizedStream), so it
    /// is intentionally *not* pruned: live-resolution entries have no anchor
    /// record in the window to re-derive from, and dropping any entry would let
    /// a finalized stream be re-watched. Bounded by the conversation's distinct
    /// stream count.
    private var finalizedStreamIds: Set<String> = []
    /// Message ids of anchor records already passed through
    /// `recordFinalizedStreams`. Anchor records are immutable for a given
    /// message id, so this lets us skip re-decoding `agentTextStreamJson` and
    /// re-classifying the same record on every window/tail page. Bounded to the
    /// currently loaded window via `pruneScannedFinalizedMessageIds()`.
    private var scannedFinalizedMessageIds: Set<String> = []
    /// Start-record timestamps for live previews, keyed by stream id.
    private var streamStartedAtById: [String: UInt64] = [:]
    private var streamSenderById: [String: String] = [:]
    /// Message ids recently marked read or awaiting a coalesced mark-read flush.
    /// This is a local dedup cache only; Marmot read marking is idempotent, so it
    /// is pruned to the loaded window and capped instead of retaining every id
    /// seen by the view model.
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
        case window
        case tailRefresh
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

    /// Identifies the inputs the cached `@`-mention candidate list was built
    /// from. Both generations are monotonic: `rosterGeneration` bumps on group
    /// membership/admin changes, `profileGeneration` bumps when resolved
    /// display-name/avatar/npub data refreshes. A change in either invalidates
    /// the cache so freshly resolved names still surface in autocomplete.
    /// Non-private so the invalidation contract can be unit-tested (#300).
    struct MentionCandidateCacheKey: Equatable {
        let rosterGeneration: UInt64
        let profileGeneration: Int
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
        let key = MentionCandidateCacheKey(
            rosterGeneration: groupMlsRefreshGeneration,
            profileGeneration: appState.profileRefreshGeneration
        )
        if let cachedMentionCandidates, cachedMentionCandidatesKey == key {
            return cachedMentionCandidates
        }
        let candidates: [ComposerMentionCandidate]
        if !groupMemberDetails.isEmpty {
            candidates = groupMemberDetails
                .filter { !$0.isSelf }
                .map { ComposerMentionCandidate(details: $0, appState: appState) }
        } else {
            candidates = members.compactMap { ComposerMentionCandidate(member: $0, appState: appState) }
        }
        cachedMentionCandidates = candidates
        cachedMentionCandidatesKey = key
        return candidates
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
        initialTimelineSnapshotTask?.cancel()
        groupStateTask?.cancel()
        groupDetailsTask?.cancel()
        readStateTask?.cancel()
        readMarkTask?.cancel()
        mediaRefreshTask?.cancel()
        tailRefreshTask?.cancel()
        for task in streamWatchTasks.values { task.cancel() }
    }

    func start() async {
        guard let appState, let accountRef = appState.activeAccountRef else { return }
        stopLiveSubscriptions()
        resetOptimisticState()
        error = nil
        if timeline.isEmpty {
            isLoading = true
            startInitialTimelineSnapshot(accountRef: accountRef)
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
        pruneMarkedReadMessageIds()
    }

    static func shouldMarkRead(_ record: AppMessageRecordFfi, isDeleted: Bool, alreadyMarked: Bool) -> Bool {
        !alreadyMarked
            && !isDeleted
            && !record.messageIdHex.isEmpty
            && record.kind == MessageSemantics.kindChat
    }

    nonisolated static func retainedMarkedReadMessageIds(
        _ current: Set<String>,
        loadedMessageIds: Set<String>,
        pendingMessageIds: Set<String>,
        limit: Int
    ) -> Set<String> {
        let pending = current.intersection(pendingMessageIds)
        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else { return pending }

        let loaded = current.intersection(loadedMessageIds)
        let retainedCandidates = loaded.union(pending)
        guard retainedCandidates.count > boundedLimit else {
            return retainedCandidates
        }

        var retained = pending
        let remainingCapacity = max(0, boundedLimit - retained.count)
        if remainingCapacity > 0 {
            for messageId in loaded.subtracting(retained).prefix(remainingCapacity) {
                retained.insert(messageId)
            }
        }
        return retained
    }

    private func pruneMarkedReadMessageIds(force: Bool = false) {
        guard force || markedReadMessageIds.count > Self.maxMarkedReadMessageIds else { return }
        markedReadMessageIds = Self.retainedMarkedReadMessageIds(
            markedReadMessageIds,
            loadedMessageIds: Set(messageById.keys),
            pendingMessageIds: pendingReadMessageIdSet,
            limit: Self.maxMarkedReadMessageIds
        )
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
        guard !messageIds.isEmpty else {
            pendingReadMessageIdSet = []
            pruneMarkedReadMessageIds(force: true)
            return
        }
        defer {
            pendingReadMessageIdSet.subtract(messageIds)
            pruneMarkedReadMessageIds(force: true)
        }
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
        pruneMarkedReadMessageIds(force: true)
    }

    private func stopLiveSubscriptions() {
        timelineTask?.cancel()
        timelineTask = nil
        initialTimelineSnapshotTask?.cancel()
        initialTimelineSnapshotTask = nil
        timelineSubscription = nil
        groupStateTask?.cancel()
        groupStateTask = nil
        groupDetailsTask?.cancel()
        groupDetailsTask = nil
        readStateTask?.cancel()
        readStateTask = nil
        cancelPendingReadMarks()
        markedReadMessageIds.removeAll()
        mediaRefreshTask?.cancel()
        mediaRefreshTask = nil
        cancelTimelineTailRefresh()
        for task in streamWatchTasks.values {
            task.cancel()
        }
        streamWatchTasks.removeAll()
        streamWatchGenerations.removeAll()
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

    private func installTimelineSubscription(_ subscription: TimelineMessagesSubscription) {
        timelineSubscription = subscription
    }

    private func clearTimelineSubscription(_ subscription: TimelineMessagesSubscription) {
        if timelineSubscription === subscription {
            timelineSubscription = nil
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
                    let client = try appState.currentMarmotClient()
                    let timelineSub = try await client.marmot.subscribeTimelineMessages(
                        accountRef: accountRef,
                        groupIdHex: groupIdHex,
                        limit: Self.timelinePageLimit
                    )
                    guard !Task.isCancelled else { return }
                    self?.error = nil
                    self?.installTimelineSubscription(timelineSub)
                    defer { self?.clearTimelineSubscription(timelineSub) }
                    if let snapshot = await client.timelineSubscriptionSnapshot(timelineSub) {
                        guard !Task.isCancelled else { return }
                        self?.applyTimelinePage(snapshot, placement: .window)
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

    private func startInitialTimelineSnapshot(accountRef: String) {
        initialTimelineSnapshotTask?.cancel()
        guard let appState else { return }
        let groupIdHex = group.groupIdHex
        initialTimelineSnapshotTask = Task { [weak self, weak appState] in
            do {
                guard let self, let appState else { return }
                let client = try appState.currentMarmotClient()
                let page = try await client.timelineMessages(
                    accountRef: accountRef,
                    query: TimelineMessageQueryFfi(
                        groupIdHex: groupIdHex,
                        search: nil,
                        before: nil,
                        beforeMessageId: nil,
                        after: nil,
                        afterMessageId: nil,
                        limit: Self.timelinePageLimit
                    )
                )
                guard !Task.isCancelled else { return }
                initialTimelineSnapshotTask = nil
                if timeline.isEmpty {
                    applyTimelinePage(page, placement: .window)
                } else {
                    isLoading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.initialTimelineSnapshotTask = nil
                if self.timeline.isEmpty {
                    self.isLoading = false
                    self.error = error.localizedDescription
                }
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
                    let client = try appState.currentMarmotClient()
                    let groupSub = try await client.marmot.subscribeGroupState(
                        accountRef: accountRef,
                        groupIdHex: groupIdHex
                    )
                    guard !Task.isCancelled else { return }
                    if let initial = await client.groupStateSubscriptionSnapshot(groupSub) {
                        guard !Task.isCancelled else { return }
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
        switch placement {
        case .window:
            applyTimelineWindowPage(page)
        case .tailRefresh:
            applyTimelineTailRefreshPage(page)
        }
    }

    func applyTimelineSubscriptionUpdate(_ update: TimelineSubscriptionUpdateFfi) {
        switch update {
        case .page(let page):
            applyTimelinePage(page, placement: .window)
        case .projection(let runtimeUpdate):
            applyTimelineProjectionUpdate(runtimeUpdate)
        }
    }

    private func applyTimelineWindowPage(_ page: TimelinePageFfi) {
        var projectionChanged = false
        let shouldEvictAbsentRecords = shouldEvictAbsentTimelineRecords(from: page)
        if shouldEvictAbsentRecords {
            let incomingMessageIds = Set(page.messages.map(\.messageIdHex).filter { !$0.isEmpty })
            for messageId in Array(messageById.keys) where !incomingMessageIds.contains(messageId) {
                projectionChanged = removeTimelineRecord(
                    messageIdHex: messageId,
                    updateTimeline: false
                ) || projectionChanged
            }
        }
        recordFinalizedStreams(in: page.messages)
        for record in page.messages {
            projectionChanged = applyTimelineRecord(record) || projectionChanged
        }
        if shouldEvictAbsentRecords {
            pruneScannedFinalizedMessageIds(keeping: Set(messageById.keys))
        }
        pruneMarkedReadMessageIds(force: true)
        hasMoreBefore = page.hasMoreBefore
        hasMoreAfter = page.hasMoreAfter
        rebuildProjectedState(projectionChanged: projectionChanged)
        isLoading = false
    }

    private func applyTimelineProjectionUpdate(_ runtimeUpdate: RuntimeProjectionUpdateFfi) {
        let update = runtimeUpdate.update
        guard update.groupIdHex == group.groupIdHex else { return }

        var projectionChanged = false
        // `changes` is authoritative for live deltas; the snapshot is still a bounded window.
        for change in update.changes {
            switch change {
            case .upsert(let trigger, let record):
                recordFinalizedStreams(in: [record])
                projectionChanged = applyTimelineRecord(record, trigger: trigger) || projectionChanged
            case .remove(let messageIdHex, _):
                projectionChanged = removeTimelineRecord(
                    messageIdHex: messageIdHex,
                    updateTimeline: false
                ) || projectionChanged
            }
        }
        pruneMarkedReadMessageIds(force: true)
        rebuildProjectedState(projectionChanged: projectionChanged)
        isLoading = false
    }

    private func shouldEvictAbsentTimelineRecords(from page: TimelinePageFfi) -> Bool {
        !hasMoreBefore && !hasMoreAfter && !page.hasMoreBefore && !page.hasMoreAfter
    }

    private func applyTimelineTailRefreshPage(_ page: TimelinePageFfi) {
        let existingMessageIds = Set(messageById.keys)
        let records = hasMoreAfter
            ? page.messages.filter { existingMessageIds.contains($0.messageIdHex) }
            : page.messages
        recordFinalizedStreams(in: records)
        var projectionChanged = false
        for record in records {
            projectionChanged = applyTimelineRecord(record) || projectionChanged
        }
        pruneScannedFinalizedMessageIds(keeping: Set(messageById.keys))
        pruneMarkedReadMessageIds(force: true)
        if !hasMoreAfter {
            hasMoreBefore = page.hasMoreBefore
            hasMoreAfter = page.hasMoreAfter
        }
        rebuildProjectedState(projectionChanged: projectionChanged)
        isLoading = false
    }

    /// Reloads the newest timeline page from Marmot. Group system rows (kind
    /// 1210) are synthesized locally when commits are processed, so a live
    /// subscription update can race with group-state refresh — especially after
    /// catch-up on a second device/simulator.
    func refreshTimelineTail() async {
        guard let request = timelineTailRefreshRequest() else { return }
        do {
            let page = try await Self.timelineTailPage(for: request)
            guard !Task.isCancelled else { return }
            applyTimelineTailRefreshPageIfCurrent(page, request: request)
        } catch {
            // Timeline subscription remains the primary live path.
        }
    }

    private func scheduleTimelineTailRefresh() {
        guard let request = timelineTailRefreshRequest() else {
            cancelTimelineTailRefresh()
            return
        }
        scheduleTimelineTailRefresh { [weak self] in
            do {
                let page = try await Self.timelineTailPage(for: request)
                guard !Task.isCancelled else { return }
                self?.applyTimelineTailRefreshPageIfCurrent(page, request: request)
            } catch {
                // Timeline subscription remains the primary live path.
            }
        }
    }

    private func scheduleTimelineTailRefresh(operation: @escaping TimelineTailRefreshOperation) {
        cancelTimelineTailRefresh()
        let generation = tailRefreshGeneration
        tailRefreshTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            await operation()
            guard !Task.isCancelled else { return }
            self?.clearTimelineTailRefreshTask(generation: generation)
        }
    }

    private func cancelTimelineTailRefresh() {
        tailRefreshGeneration = TimelineTailRefreshTaskLifetime.nextGeneration(after: tailRefreshGeneration)
        tailRefreshTask?.cancel()
        tailRefreshTask = nil
    }

    private func clearTimelineTailRefreshTask(generation: UInt64) {
        guard TimelineTailRefreshTaskLifetime.shouldClearStoredTask(
            currentGeneration: tailRefreshGeneration,
            completedGeneration: generation
        ) else { return }
        tailRefreshTask = nil
    }

    private func timelineTailRefreshRequest() -> TimelineTailRefreshRequest? {
        guard let appState, let accountRef = appState.activeAccountRef else { return nil }
        do {
            return TimelineTailRefreshRequest(
                client: try appState.currentMarmotClient(),
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )
        } catch {
            return nil
        }
    }

    private static func timelineTailPage(for request: TimelineTailRefreshRequest) async throws -> TimelinePageFfi {
        try await request.client.timelineMessages(
            accountRef: request.accountRef,
            query: TimelineMessageQueryFfi(
                groupIdHex: request.groupIdHex,
                search: nil,
                before: nil,
                beforeMessageId: nil,
                after: nil,
                afterMessageId: nil,
                limit: Self.timelinePageLimit
            )
        )
    }

    private func applyTimelineTailRefreshPageIfCurrent(
        _ page: TimelinePageFfi,
        request: TimelineTailRefreshRequest
    ) {
        guard appState?.activeAccountRef == request.accountRef,
              group.groupIdHex == request.groupIdHex else { return }
        applyTimelinePage(page, placement: .tailRefresh)
    }

#if DEBUG
    func scheduleTimelineTailRefreshForTesting(operation: @escaping TimelineTailRefreshOperation) {
        scheduleTimelineTailRefresh(operation: operation)
    }

    func cancelTimelineTailRefreshForTesting() {
        cancelTimelineTailRefresh()
    }

    var hasTimelineTailRefreshTaskForTesting: Bool {
        tailRefreshTask != nil
    }
#endif

    func loadOlderTimelinePage() async {
        guard hasMoreBefore, !isLoadingOlder, let timelineSubscription else { return }

        let previousOldestMessageId = oldestLoadedTimelineMessageId
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let page = try await timelineSubscription.paginateBackwards(count: Self.timelinePageLimit)
            guard !Task.isCancelled else { return }
            let movedOlder = Self.paginationMovedOlder(
                previousOldestMessageId: previousOldestMessageId,
                nextMessageIds: page.messages.map(\.messageIdHex)
            )
            applyTimelinePage(page, placement: .window)
            if !movedOlder, page.hasMoreBefore {
                hasMoreBefore = false
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadNewerTimelinePage() async {
        guard hasMoreAfter, !isLoadingNewer, let timelineSubscription else { return }

        let previousNewestMessageId = newestLoadedTimelineMessageId
        isLoadingNewer = true
        defer { isLoadingNewer = false }
        do {
            let page = try await timelineSubscription.paginateForwards(count: Self.timelinePageLimit)
            guard !Task.isCancelled else { return }
            let movedNewer = Self.paginationMovedNewer(
                previousNewestMessageId: previousNewestMessageId,
                nextMessageIds: page.messages.map(\.messageIdHex)
            )
            applyTimelinePage(page, placement: .window)
            if !movedNewer, page.hasMoreAfter {
                hasMoreAfter = false
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    nonisolated static func paginationMovedOlder(
        previousOldestMessageId: String?,
        nextMessageIds: [String]
    ) -> Bool {
        guard let previousOldestMessageId else { return !nextMessageIds.isEmpty }
        guard let nextOldestMessageId = nextMessageIds.first else { return false }
        return nextOldestMessageId != previousOldestMessageId
    }

    nonisolated static func paginationMovedNewer(
        previousNewestMessageId: String?,
        nextMessageIds: [String]
    ) -> Bool {
        guard let previousNewestMessageId else { return !nextMessageIds.isEmpty }
        guard let nextNewestMessageId = nextMessageIds.last else { return false }
        return nextNewestMessageId != previousNewestMessageId
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
        if !pendingReadMessageIdSet.contains(messageIdHex) {
            markedReadMessageIds.remove(messageIdHex)
        }
        scannedFinalizedMessageIds.remove(messageIdHex)
        let timelineChanged = updateTimeline
            ? removeTimelineItem(id: "msg:\(messageIdHex)")
            : false
        return existed || timelineChanged
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
        next = Self.normalizedTimeline(
            from: next,
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
        next.append(item)
        next = Self.normalizedTimeline(
            from: next,
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

    /// Builds the canonical timeline ordering from an arbitrary set of rows:
    /// sort by `timelineItemComesBefore` (timestamp, then id), then pull replies
    /// directly under their parent via `normalizedReplyOrdering`. Both the full
    /// `rebuildTimeline()` and the incremental single-row upsert path go through
    /// here so they can never diverge — incrementally inserting into the already
    /// reply-normalized (non-monotonic) array and binary-searching it produced an
    /// order that disagreed with a full rebuild (#202).
    static func normalizedTimeline(
        from items: [TimelineItem],
        replyTargetId: (AppMessageRecordFfi) -> String?
    ) -> [TimelineItem] {
        var sorted = items
        sorted.sort(by: timelineItemComesBefore)
        return normalizedReplyOrdering(sorted, replyTargetId: replyTargetId)
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

    private var oldestLoadedTimelineMessageId: String? {
        timeline.lazy.compactMap(Self.messageId(in:)).first
    }

    private var newestLoadedTimelineMessageId: String? {
        timeline.lazy.compactMap(Self.messageId(in:)).last
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
        mediaRecordReferencesByKey[MediaDownloadInFlightKey(reference: reference)]
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

    private func replaceMediaRecordsByMessageId(_ recordsByMessageId: [String: [MediaRecordFfi]]) {
        mediaRecordsByMessageId = recordsByMessageId
        rebuildMediaRecordReferenceIndex()
    }

    @discardableResult
    private func replaceMediaRecords(_ records: [MediaRecordFfi], forMessageId messageIdHex: String) -> Bool {
        guard mediaRecordsByMessageId[messageIdHex] != records else { return false }
        mediaRecordsByMessageId[messageIdHex] = records
        rebuildMediaRecordReferenceIndex()
        return true
    }

    private func rebuildMediaRecordReferenceIndex() {
        var next: [MediaDownloadInFlightKey: MediaAttachmentReferenceFfi] = [:]
        for records in mediaRecordsByMessageId.values {
            for record in records {
                next[MediaDownloadInFlightKey(reference: record.reference)] = record.reference
            }
        }
        mediaRecordReferencesByKey = next
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
            replaceMediaRecordsByMessageId(next)
            noteTimelineProjectionChanged()
        } catch {
            // Media rows are a display accelerator for decrypt/download. The
            // timeline remains usable and future updates retry the refresh.
        }
    }

#if DEBUG
    func replaceMediaRecordsForTesting(_ recordsByMessageId: [String: [MediaRecordFfi]]) {
        replaceMediaRecordsByMessageId(recordsByMessageId)
    }

    func installPendingMediaForTesting(rowId: String, items: [MessageMediaAttachment]) {
        pendingMediaByRowId[rowId] = items
    }

    func pendingMediaForTesting(rowId: String) -> [MessageMediaAttachment]? {
        pendingMediaByRowId[rowId]
    }

    func mediaRecordReferenceForTesting(
        matching reference: MediaAttachmentReferenceFfi
    ) -> MediaAttachmentReferenceFfi? {
        mediaRecordReference(matching: reference)
    }

    var mediaRecordReferenceIndexCountForTesting: Int {
        mediaRecordReferencesByKey.count
    }
#endif

    @discardableResult
    private func reconcilePendingOutgoingMessage(with record: AppMessageRecordFfi, replyTargetId: String?) -> Bool {
        guard record.direction == "sent" else { return false }
        let projectedReplyTarget = replyTargetId ?? Self.replyTargetMessageId(in: record)
        let matchingPendingMessages = transientTimelineItems.filter { key, item in
            Self.pendingOutgoingMessage(
                item,
                matches: record,
                replyTargetId: projectedReplyTarget,
                pendingHasStagedMedia: pendingMediaByRowId[key]?.isEmpty == false
            )
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
        replyTargetId: String?,
        pendingHasStagedMedia: Bool
    ) -> Bool {
        guard case .message(let pending, let status) = item.kind,
              status == .sending || status == .sent,
              pending.messageIdHex.isEmpty,
              pending.direction == "sent" else {
            return false
        }

        // A media optimistic record is built with `tags: []` and
        // `plaintext: caption`, so it is otherwise indistinguishable from a
        // plain text send carrying the same text. Without a media
        // discriminator, the incoming confirmation for one can reconcile away
        // the other's pending bubble (#262). Treat the pending row as media
        // when it has staged local attachments or its own record already
        // classifies as media, and require it to agree with the incoming
        // record's media classification.
        let pendingIsMedia = pendingHasStagedMedia || isMediaRecord(pending)
        guard pendingIsMedia == isMediaRecord(record) else {
            return false
        }

        return pending.groupIdHex == record.groupIdHex
            && pending.sender == record.sender
            && pending.plaintext == record.plaintext
            && pending.kind == record.kind
            && replyTargetMessageId(in: pending) == replyTargetId
    }

    private static func isMediaRecord(_ record: AppMessageRecordFfi) -> Bool {
        if case .media = MessageSemantics.classify(record) {
            return true
        }
        return false
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

    /// Pure decision for whether a naturally-completing stream watch task may
    /// clear its own dictionary entry. Only the task whose generation still
    /// matches the stored generation owns the key; a stale task whose key was
    /// reused by a later re-watch must not tear that re-watch down. Extracted
    /// so the generation-guard is observable without a live broker subscription.
    static func shouldClearCompletedStreamWatch(storedGeneration: UUID?, taskGeneration: UUID) -> Bool {
        storedGeneration == taskGeneration
    }

    /// Clear a stream watch entry when its task exits naturally (the broker
    /// closed the stream by returning nil from next()). Generation-guarded:
    /// only clears if the stored generation still matches this task, so a
    /// re-watch that reused the key isn't torn down by a stale task's exit.
    /// Mirrors `NotificationDriver.clearCompletedTask`.
    private func clearCompletedStreamWatch(streamId: String, generation: UUID) {
        guard Self.shouldClearCompletedStreamWatch(
            storedGeneration: streamWatchGenerations[streamId],
            taskGeneration: generation
        ) else { return }
        streamWatchTasks[streamId] = nil
        streamWatchGenerations[streamId] = nil
    }

    /// Tear down a live preview that produced no usable transcript (the stream
    /// failed). agentnoise falls back to a plain chat reply in that case, which
    /// arrives as a normal message — so drop the preview and mark the stream
    /// finalized so trailing updates can't recreate it.
    private func endStream(streamId: String) {
        finalizedStreamIds.insert(streamId)
        streamWatchTasks[streamId]?.cancel()
        streamWatchTasks[streamId] = nil
        streamWatchGenerations[streamId] = nil
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
        streamWatchGenerations[streamId] = nil
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
        streamWatchGenerations[streamId] = nil
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

        // Claim the send slot before the first suspension point. The off-MainActor
        // markdown parse below introduces an `await`, so leaving the flag unset
        // would let a second send task start during a long parse (#226 review).
        sendInFlight = true
        defer { sendInFlight = false }

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
        // Parse markdown off the MainActor: `parseMarkdown` is a synchronous
        // rustCall whose cost scales with message length, so building the
        // optimistic record inline would stall the composer at send time (#226).
        let contentTokens = await appState.parseMarkdown(text: outgoing)
        let optimistic = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: group.groupIdHex,
            sender: appState.activeAccount?.accountIdHex ?? "",
            plaintext: outgoing,
            contentTokens: contentTokens,
            kind: MessageSemantics.kindChat,
            tags: optimisticTags,
            recordedAt: now,
            receivedAt: now
        )
        applyPendingOutgoingMessage(tempId: tempId, record: optimistic)
        replyingTo = nil

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

        // Claim the send slot before the first suspension point. The off-MainActor
        // caption parse below introduces an `await`, so leaving the flag unset
        // would let a second send task start during a long parse (#226 review).
        sendInFlight = true
        defer { sendInFlight = false }

        let captionTokens: MarkdownDocumentFfi = outgoingCaption.isEmpty
            ? .emptyDocument
            : await appState.parseMarkdown(text: outgoingCaption)
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
                if replaceMediaRecords(nextRecords, forMessageId: messageId) {
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
        let removedPendingMedia = pendingMediaByRowId.removeValue(forKey: "msg:\(tempId)")
        projectionChanged = (removedPendingMedia != nil) || projectionChanged
        projectionChanged = removeTimelineItem(id: "msg:\(tempId)") || projectionChanged
        if realId.isEmpty {
            // No server message id: the row stays transient under "msg:\(tempId)".
            // Restore the pending media we just removed so the just-sent
            // attachments keep rendering — without a real message id there is no
            // mediaRecordsByMessageId entry to fall back on, so dropping this
            // would silently blank the bubble's images.
            if let removedPendingMedia {
                pendingMediaByRowId[rowId] = removedPendingMedia
            }
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
            let generation = UUID()
            let task = Task { [weak self] in
                while !Task.isCancelled, let update = await subscription.next() {
                    self?.applyStreamUpdate(streamId: streamId, sender: sender, update: update)
                }
                // The broker can close a stream silently by returning nil from
                // next() without a .finished/.failed/abort update ever flowing
                // through endStream/finalizeStreamBubble/resolveFinalizedStream.
                // Clear our own entry on that natural exit so the admission
                // guard doesn't treat the dead key as "already watching" and
                // lock out re-subscription. Generation-guarded so a re-watch
                // that reused the key isn't torn down by this stale exit.
                self?.clearCompletedStreamWatch(streamId: streamId, generation: generation)
            }
            streamWatchTasks[streamId] = task
            streamWatchGenerations[streamId] = generation
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
        let itemTimestamp = transientTimelineItems[rowId]?.timestamp ?? timestamp
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
        let item = TimelineItem(
            id: rowId,
            kind: .message(record: record, status: status),
            timestamp: itemTimestamp
        )
        transientTimelineItems[rowId] = item
        if upsertTimelineItem(item) {
            noteTimelineProjectionChanged()
        }
    }

    private func recordFinalizedStreams(in records: [TimelineMessageRecordFfi]) {
        for record in records {
            // Anchor records are immutable for a given message id, so once a
            // record has been scanned its finalized-stream classification can't
            // change. Skip the JSON decode + classification on later pages.
            let messageId = record.messageIdHex
            if !messageId.isEmpty {
                guard scannedFinalizedMessageIds.insert(messageId).inserted else { continue }
            }
            let appRecord = Self.appMessageRecord(from: record)
            if let streamId = Self.finalizedStreamId(from: record, appRecord: appRecord) {
                finalizedStreamIds.insert(streamId)
            }
        }
    }

    /// Bound `scannedFinalizedMessageIds` to the records still represented in
    /// the loaded window. Records evicted from the window can reappear on a
    /// later page, and re-scanning them then is idempotent (it only re-inserts
    /// into `finalizedStreamIds`, which is never pruned), so dropping their
    /// scan markers is safe and keeps the cache from growing without bound.
    private func pruneScannedFinalizedMessageIds(keeping loadedMessageIds: Set<String>) {
        guard !scannedFinalizedMessageIds.isEmpty else { return }
        scannedFinalizedMessageIds.formIntersection(loadedMessageIds)
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

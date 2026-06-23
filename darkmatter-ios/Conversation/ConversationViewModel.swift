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

enum ConversationRuntimeStartDecision: Equatable {
    case skipForegroundWork
    case loadLocalSnapshot(startLiveWork: Bool)

    static func evaluate(canLoadLocalSnapshot: Bool, canStartLiveWork: Bool) -> Self {
        guard canLoadLocalSnapshot || canStartLiveWork else {
            return .skipForegroundWork
        }
        return .loadLocalSnapshot(startLiveWork: canStartLiveWork)
    }
}

private struct TimelineTailRefreshRequest {
    let client: MarmotClient
    let accountRef: String
    let groupIdHex: String
}

typealias TimelineTailRefreshOperation = @MainActor () async -> Void

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
    /// Coarse invalidation token for projection data read through methods.
    private(set) var timelineProjectionGeneration = 0
    private(set) var hasMoreBefore = false
    private(set) var hasMoreAfter = false
    private(set) var isLoadingOlder = false
    private(set) var isLoadingNewer = false
    private(set) var isLoading = false
    private(set) var sendInFlight = false
    private(set) var error: String?
    private(set) var isMediaRecordsRefreshPending = false

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
    private var tailRefreshTask: Task<Void, Never>?
    private var tailRefreshGeneration: UInt64 = 0

    private static let timelinePageLimit: UInt32 = 50
    private static let liveSubscriptionInitialRetryDelayNanoseconds: UInt64 = 500_000_000
    private static let liveSubscriptionMaximumRetryDelayNanoseconds: UInt64 = 8_000_000_000
    nonisolated static let maxSystemTimelineItems = 64

    /// Renderable timeline messages we've loaded by id.
    @ObservationIgnored private var messageById: [String: AppMessageRecordFfi] = [:]
    @ObservationIgnored private var messageStatusById: [String: MessageStatus] = [:]
    @ObservationIgnored private var replyTargetByMessageId: [String: String] = [:]
    @ObservationIgnored private var replyPreviewsByMessageId: [String: TimelineReplyPreviewFfi] = [:]
    /// Per-target reaction tally cache: the authoritative server summary
    /// (mirrored at ingest), the optimistic react/un-react overlay, and the
    /// aggregated tallies. The optimistic toggle orchestration stays here; the
    /// state + aggregation live in the cache.
    @ObservationIgnored private let reactionProjections = ConversationReactionProjectionCache()
    @ObservationIgnored private let markdownProjections = ConversationMarkdownProjectionCache()
    /// Tombstone projection: projected deletes (ingest) ∪ optimistic deletes,
    /// read via `isDeleted` and fed to the reaction recompute.
    @ObservationIgnored private let deletedProjections = ConversationDeletedMessageProjection()
    @ObservationIgnored private var timelineSubscription: TimelineMessagesSubscription?
    @ObservationIgnored private var systemTimelineItems: [TimelineItem] = []
    @ObservationIgnored private var transientTimelineItems: [String: TimelineItem] = [:]
    /// Per-row media display cache: resolved references (mirrored at ingest),
    /// optimistic pending media (from the send pipeline), and the built display
    /// projection. A dumb mirror of the row — no iOS-side derivation, and no
    /// separate `listMedia` round-trip to recover `sourceEpoch`.
    @ObservationIgnored private let mediaProjections = ConversationMediaProjectionCache()
    @ObservationIgnored private let mediaDownloader = ConversationMediaDownloader()
    // Lazy so its `[weak self]` loaded-window closure can capture a fully
    // initialized self; first touched on the post-start apply/mark paths.
    @ObservationIgnored private lazy var readMarker = ConversationReadMarker(
        groupIdHex: group.groupIdHex,
        maxMarkedReadMessageIds: Int(Self.timelinePageLimit) * 4,
        appState: appState,
        loadedMessageIds: { [weak self] in
            guard let self else { return [] }
            return Set(self.messageById.keys)
        },
        onChatListRowUpdated: onChatListRowUpdated
    )
    /// Cached `@`-mention autocomplete candidates and the generation pair they
    /// were built from. `mentionCandidates(for:)` runs on every composer
    /// keystroke; rebuilding the candidate array (and re-deriving each
    /// candidate's lowercased match fields) per keystroke is avoidable work on
    /// the MainActor typing hot path (see issue #300). The cache is rebuilt only
    /// when the group roster (`groupMlsRefreshGeneration`) or resolved profile
    /// data (`AppState.profileRefreshGeneration`) actually changes.
    @ObservationIgnored private let mentionController = ComposerMentionController()
    /// Agent-text-stream (QUIC) watch subsystem. Invoked from the timeline ingest
    /// (`watchStartIfNeeded`/`recordFinalizedStreams`/`resolveFinalizedStream`/
    /// `dropMatchingStreamPreview`) and writes its synthetic stream/debug rows
    /// back through `StreamWatcherTimelineSink` (this view model). Lazy so the
    /// sink wiring captures a fully initialized self.
    @ObservationIgnored private lazy var streamWatcher: StreamWatcher = {
        let watcher = StreamWatcher(appState: appState, groupIdHex: group.groupIdHex)
        watcher.sink = self
        return watcher
    }()
#if DEBUG
    var streamTextEntryCountForTesting: Int { streamWatcher.streamTextEntryCountForTesting }
    var streamTextLengthEntryCountForTesting: Int { streamWatcher.streamTextLengthEntryCountForTesting }
    var scannedFinalizedMessageIdCountForTesting: Int { streamWatcher.scannedFinalizedMessageIdCountForTesting }
    var finalizedStreamIdCountForTesting: Int { streamWatcher.finalizedStreamIdCountForTesting }
    var markedReadMessageIdsForTesting: Set<String> { readMarker.markedReadMessageIdsForTesting }
    var mediaItemProjectionBuildCountForTesting: Int { mediaProjections.buildCountForTesting }

    func insertMarkedReadMessageIdsForTesting(_ messageIds: Set<String>) {
        readMarker.insertMarkedReadMessageIdsForTesting(messageIds)
    }

    func insertPendingReadMessageIdsForTesting(_ messageIds: [String]) {
        readMarker.insertPendingReadMessageIdsForTesting(messageIds)
    }
#endif
    /// Transient QUIC debug rows keyed by timeline id (streaming debug only).
    /// Written by `StreamWatcher` via the sink; consumed by `rebuildTimeline`.
    @ObservationIgnored private var streamDebugTimelineItems: [String: TimelineItem] = [:]

    var streamingDebugEnabled: Bool {
        appState?.streamingDebugEnabled == true
    }

    /// First-open load timings. Visible under category "conversation-load" in
    /// Console.app. Measures how long each Marmot read on the open path takes so
    /// we can tell whether the storage-backed timeline snapshot or the
    /// worker-backed group details dominate first-open latency. Durations only —
    /// no chat content.
    private static let loadLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.darkmatter",
        category: "conversation-load"
    )

    private func logLoadDuration(_ label: String, since start: ContinuousClock.Instant) {
        let elapsed = start.duration(to: ContinuousClock.now).components
        let elapsedMs = Double(elapsed.seconds) * 1000
            + Double(elapsed.attoseconds) / 1_000_000_000_000_000
        Self.loadLog.debug("\(label, privacy: .public): \(elapsedMs, format: .fixed(precision: 0), privacy: .public)ms")
    }

    enum TimelinePagePlacement {
        case window
        case tailRefresh
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

    var canSendMessages: Bool {
        GroupManagementPresentation.isActiveMember(
            state: managementState,
            members: members,
            groupMemberDetails: groupMemberDetails,
            myAccountId: myAccountId
        )
    }

    var inactiveGroupMessage: String? {
        canSendMessages ? nil : GroupManagementPresentation.inactiveGroupComposerMessage
    }

    var canSendMediaAttachments: Bool {
        canSendMessages
            && group.encryptedMedia.required
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
        mentionController.candidates(
            for: draft,
            appState: appState,
            members: members,
            groupMemberDetails: groupMemberDetails,
            rosterGeneration: groupMlsRefreshGeneration
        )
    }

    func applyMentionSelection(_ candidate: ComposerMentionCandidate, to draft: inout String) {
        mentionController.applySelection(candidate, to: &draft)
    }

    func managementAction(for memberIdHex: String) -> GroupMemberActionStateFfi? {
        managementState?.memberActions.first { $0.memberIdHex == memberIdHex }
    }

    /// Reaction tallies for a target message (empty when none).
    func reactions(for messageIdHex: String) -> [ReactionTally] {
        _ = timelineProjectionGeneration
        return reactionProjections.tallies(forMessageId: messageIdHex)
    }

    func markdownDisplayBlocks(for item: TimelineItem) -> [MarkdownDisplayBlock]? {
        _ = timelineProjectionGeneration
        return markdownProjections.blocks(for: item)
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
        tailRefreshTask?.cancel()
        streamWatcher.cancelAll()
    }

    func start() async {
        guard let appState,
              let accountRef = appState.activeAccountRef
        else { return }
        let canLoadLocalSnapshot = appState.canUseRuntimeForLocalForegroundWork
        let canStartLiveWork = appState.canUseRuntimeForForegroundWork
        let startDecision = ConversationRuntimeStartDecision.evaluate(
            canLoadLocalSnapshot: canLoadLocalSnapshot,
            canStartLiveWork: canStartLiveWork
        )
        stopLiveSubscriptions()
        guard startDecision != .skipForegroundWork else {
            initialTimelineSnapshotTask?.cancel()
            return
        }
        resetOptimisticState()
        error = nil
        if canLoadLocalSnapshot, timeline.isEmpty {
            isLoading = true
            startInitialTimelineSnapshot(accountRef: accountRef)
        }
        guard case .loadLocalSnapshot(startLiveWork: true) = startDecision else { return }
        startLiveTimeline(accountRef: accountRef)
        startLiveGroupState(accountRef: accountRef)
        startDeferredGroupDetails(accountRef: accountRef)
        startDeferredReadState()
    }

    func markReadIfVisible(_ record: AppMessageRecordFfi) async {
        await readMarker.markReadIfVisible(record, isDeleted: isDeleted(record.messageIdHex))
    }

    private func pruneMarkedReadMessageIds(force: Bool = false) {
        readMarker.pruneMarkedReadMessageIds(force: force)
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
        guard let appState,
              appState.canUseRuntimeForForegroundWork,
              let accountRef = appState.activeAccountRef
        else { return }
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
        readMarker.cancelPendingReadMarks()
        readMarker.clearMarks()
        cancelTimelineTailRefresh()
        streamWatcher.cancelAll()
    }

    private func resetOptimisticState() {
        let backingChanged = deletedProjections.hasOptimistic ||
            reactionProjections.hasOptimistic ||
            !systemTimelineItems.isEmpty ||
            mediaProjections.hasPending
        deletedProjections.removeAllOptimistic()
        reactionProjections.removeAllOptimistic()
        systemTimelineItems.removeAll()
        mediaProjections.removeAllPending()
        let deletedChanged = deletedProjections.rebuild()
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

    func seedOptimisticStateForTesting(
        deletedMessageIdHex: String,
        reactionTargetMessageIdHex: String,
        emoji: String,
        sender: String
    ) {
        deletedProjections.insertOptimistic(deletedMessageIdHex)
        let reactionId = "optimistic-\(reactionTargetMessageIdHex)-\(emoji)"
        reactionProjections.setRecord(
            AppMessageRecordFfi(
                messageIdHex: reactionId,
                direction: "sent",
                groupIdHex: group.groupIdHex,
                sender: sender,
                plaintext: emoji,
                kind: MessageSemantics.kindReaction,
                tags: [MessageTagFfi(values: [MessageSemantics.eventRefTag, reactionTargetMessageIdHex])],
                recordedAt: 1,
                receivedAt: 1
            ),
            forKey: reactionId
        )
        _ = deletedProjections.rebuild()
        _ = recomputeReactions()
    }
#endif

    private func startLiveTimeline(accountRef: String) {
        guard let appState, appState.canUseRuntimeForForegroundWork else { return }
        let groupIdHex = group.groupIdHex
        timelineTask = Task { [weak self, weak appState] in
            var retryDelay = Self.liveSubscriptionInitialRetryDelayNanoseconds
            while !Task.isCancelled {
                do {
                    guard let appState, appState.canUseRuntimeForForegroundWork else { return }
                    let client = try appState.currentMarmotClient()
                    let subscribeStart = ContinuousClock.now
                    let timelineSub = try await client.marmot.subscribeTimelineMessages(
                        accountRef: accountRef,
                        groupIdHex: groupIdHex,
                        limit: Self.timelinePageLimit
                    )
                    self?.logLoadDuration("timeline.subscribe", since: subscribeStart)
                    guard !Task.isCancelled else { return }
                    self?.error = nil
                    self?.installTimelineSubscription(timelineSub)
                    defer { self?.clearTimelineSubscription(timelineSub) }
                    let snapshotStart = ContinuousClock.now
                    if let snapshot = await client.timelineSubscriptionSnapshot(timelineSub) {
                        self?.logLoadDuration("timeline.snapshot", since: snapshotStart)
                        guard !Task.isCancelled,
                              appState.canUseRuntimeForForegroundWork
                        else { return }
                        self?.applyTimelinePage(snapshot, placement: .window)
                    }
                    self?.isLoading = false
                    for await update in SubscriptionDriver.timelineMessageUpdates(timelineSub) {
                        guard !Task.isCancelled,
                              appState.canUseRuntimeForForegroundWork
                        else { return }
                        retryDelay = Self.liveSubscriptionInitialRetryDelayNanoseconds
                        self?.applyTimelineSubscriptionUpdate(update)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled,
                          appState?.canUseRuntimeForForegroundWork == true
                    else { return }
                    self?.isLoading = false
                    self?.error = error.localizedDescription
                }
                guard !Task.isCancelled,
                      appState?.canUseRuntimeForForegroundWork == true
                else { return }
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
        guard let appState, appState.canUseRuntimeForLocalForegroundWork else { return }
        let groupIdHex = group.groupIdHex
        initialTimelineSnapshotTask = Task { [weak self, weak appState] in
            do {
                guard let self,
                      let appState,
                      appState.canUseRuntimeForLocalForegroundWork
                else { return }
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
        guard let appState, appState.canUseRuntimeForForegroundWork else { return }
        let groupIdHex = group.groupIdHex
        groupStateTask = Task { [weak self, weak appState] in
            var retryDelay = Self.liveSubscriptionInitialRetryDelayNanoseconds
            while !Task.isCancelled {
                do {
                    guard let appState, appState.canUseRuntimeForForegroundWork else { return }
                    let client = try appState.currentMarmotClient()
                    let groupSub = try await client.marmot.subscribeGroupState(
                        accountRef: accountRef,
                        groupIdHex: groupIdHex
                    )
                    guard !Task.isCancelled,
                          appState.canUseRuntimeForForegroundWork
                    else { return }
                    if let initial = await client.groupStateSubscriptionSnapshot(groupSub) {
                        guard !Task.isCancelled,
                              appState.canUseRuntimeForForegroundWork
                        else { return }
                        self?.applyGroupRecord(initial)
                    }
                    for await record in SubscriptionDriver.groupState(groupSub) {
                        guard !Task.isCancelled,
                              appState.canUseRuntimeForForegroundWork
                        else { return }
                        retryDelay = Self.liveSubscriptionInitialRetryDelayNanoseconds
                        await self?.applyGroupUpdate(record)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.error = error.localizedDescription
                }
                guard !Task.isCancelled,
                      appState?.canUseRuntimeForForegroundWork == true
                else { return }
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
        guard let appState, appState.canUseRuntimeForForegroundWork else { return }
        let groupIdHex = group.groupIdHex
        groupDetailsTask = Task { [weak self, weak appState] in
            guard let self,
                  let appState,
                  appState.canUseRuntimeForForegroundWork
            else { return }
            if await self.refreshGroupManagement() {
                return
            }
            guard !Task.isCancelled,
                  appState.canUseRuntimeForForegroundWork
            else { return }
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

    /// Forwarder retained for tests; the watch subsystem lives in `StreamWatcher`.
    static func agentStreamStartIdToWatch(
        from record: AppMessageRecordFfi,
        finalizedStreamIds: Set<String>,
        trigger: TimelineUpdateTriggerFfi?
    ) -> String? {
        StreamWatcher.agentStreamStartIdToWatch(
            from: record,
            finalizedStreamIds: finalizedStreamIds,
            trigger: trigger
        )
    }

    func applyStreamUpdate(streamId: String, sender: String, update: AgentStreamUpdateFfi) {
        streamWatcher.applyStreamUpdate(streamId: streamId, sender: sender, update: update)
    }

    /// Forwarder retained for tests; the watch subsystem lives in `StreamWatcher`.
    nonisolated static func streamPreviewTimestamp(startedAt: UInt64?, fallback: UInt64) -> UInt64 {
        StreamWatcher.streamPreviewTimestamp(startedAt: startedAt, fallback: fallback)
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
        streamWatcher.recordFinalizedStreams(in: page.messages)
        for record in page.messages {
            projectionChanged = applyTimelineRecord(record) || projectionChanged
        }
        if shouldEvictAbsentRecords {
            streamWatcher.pruneScannedFinalizedMessageIds(keeping: Set(messageById.keys))
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
                streamWatcher.recordFinalizedStreams(in: [record])
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
        (!page.hasMoreBefore && !page.hasMoreAfter)
            || hasMoreBefore != page.hasMoreBefore
            || hasMoreAfter != page.hasMoreAfter
    }

    private func applyTimelineTailRefreshPage(_ page: TimelinePageFfi) {
        let existingMessageIds = Set(messageById.keys)
        let records = hasMoreAfter
            ? page.messages.filter { existingMessageIds.contains($0.messageIdHex) }
            : page.messages
        streamWatcher.recordFinalizedStreams(in: records)
        var projectionChanged = false
        for record in records {
            projectionChanged = applyTimelineRecord(record) || projectionChanged
        }
        streamWatcher.pruneScannedFinalizedMessageIds(keeping: Set(messageById.keys))
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
            let movedOlder = ConversationPaginationPolicy.movedOlder(
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
            let movedNewer = ConversationPaginationPolicy.movedNewer(
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

        projectionChanged = true
        messageById[appRecord.messageIdHex] = appRecord
        messageStatusById[appRecord.messageIdHex] = appRecord.direction == "sent" ? .sent : .received
        replyTargetByMessageId[appRecord.messageIdHex] = record.replyToMessageIdHex
        replyPreviewsByMessageId[appRecord.messageIdHex] = record.replyPreview
        // Media now arrives resolved on the row (Marmot resolves imeta + epoch);
        // mirror it instead of re-classifying tags or a separate listMedia pass.
        mediaProjections.setReferences(record.media, forMessageId: appRecord.messageIdHex)
        reactionProjections.setSummary(record.reactions, forMessageId: appRecord.messageIdHex)
        reactionProjections.pruneConfirmedOptimistic(
            target: appRecord.messageIdHex,
            summary: record.reactions,
            me: myAccountId ?? ""
        )
        deletedProjections.setProjected(deleted: record.deleted, forMessageId: record.messageIdHex)
        projectionChanged = reconcilePendingOutgoingMessage(
            with: appRecord,
            replyTargetId: record.replyToMessageIdHex
        ) || projectionChanged

        if let streamId = StreamWatcher.finalizedStreamId(from: record, appRecord: appRecord) {
            projectionChanged = streamWatcher.resolveFinalizedStream(streamId: streamId) || projectionChanged
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
        streamWatcher.dropMatchingStreamPreviewIfNeeded(for: appRecord, semantics: semantics, trigger: trigger)
        streamWatcher.watchStartIfNeeded(appRecord, trigger: trigger)
        return projectionChanged
    }

    @discardableResult
    private func removeTimelineRecord(messageIdHex: String, updateTimeline: Bool = true) -> Bool {
        let existed = messageById[messageIdHex] != nil
        messageById[messageIdHex] = nil
        messageStatusById[messageIdHex] = nil
        replyTargetByMessageId[messageIdHex] = nil
        replyPreviewsByMessageId[messageIdHex] = nil
        mediaProjections.removeReferences(forMessageId: messageIdHex)
        reactionProjections.removeSummary(forMessageId: messageIdHex)
        deletedProjections.removeProjected(forMessageId: messageIdHex)
        readMarker.forgetMarkIfNotPending(messageIdHex)
        streamWatcher.forgetScannedFinalized(messageIdHex)
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
        changed = deletedProjections.rebuild() || changed
        changed = recomputeReactions() || changed
        if shouldRebuildTimeline {
            changed = rebuildTimeline() || changed
        }
        if changed {
            noteTimelineProjectionChanged()
        }
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
        let markdownChanged = markdownProjections.rebuild(
            for: next,
            onlyRowsWithMentions: false,
            resolver: mentionDisplayNameResolver
        )
        let mediaChanged = mediaProjections.rebuild(for: next)
        return assignTimeline(next) || markdownChanged || mediaChanged
    }

    func refreshStreamingDebugPresentation() {
        var changed = false
        if !streamingDebugEnabled {
            changed = !streamDebugTimelineItems.isEmpty
            streamDebugTimelineItems.removeAll()
            streamWatcher.resetDebugSequence()
        }
        changed = rebuildTimeline() || changed
        if changed {
            noteTimelineProjectionChanged()
        }
    }

    func refreshProfileDependentTimelineProjections() {
        if markdownProjections.rebuild(for: timeline, onlyRowsWithMentions: true, resolver: mentionDisplayNameResolver) {
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
        let markdownChanged = markdownProjections.update(for: item, resolver: mentionDisplayNameResolver)
        let mediaChanged = mediaProjections.update(for: item)
        return assignTimeline(next) || markdownChanged || mediaChanged
    }

    @discardableResult
    private func removeTimelineItem(id: String) -> Bool {
        let next = timeline.filter { $0.id != id }
        let markdownChanged = markdownProjections.remove(rowId: id)
        let mediaChanged = mediaProjections.remove(rowId: id)
        return assignTimeline(next) || markdownChanged || mediaChanged
    }

    private func assignTimeline(_ next: [TimelineItem]) -> Bool {
        guard timeline != next else { return false }
        timeline = next
        return true
    }

    private func noteTimelineProjectionChanged() {
        timelineProjectionGeneration += 1
    }

    /// Resolves a loaded message id to its current visible timeline row, for the
    /// media cache's by-message-id projection refresh. Returns nil when the
    /// message is unloaded or not currently visible.
    private func visibleTimelineItem(forMessageId messageIdHex: String) -> TimelineItem? {
        guard let record = messageById[messageIdHex] else { return nil }
        return visibleTimelineItem(for: record, status: messageStatusById[messageIdHex])
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
        return mediaProjections.items(for: item)
    }

    func mediaItems(for record: AppMessageRecordFfi) -> [MessageMediaAttachment] {
        _ = timelineProjectionGeneration
        return mediaProjections.build(for: record, ownerId: record.messageIdHex)
    }

    func data(for media: MessageMediaAttachment) async throws -> Data {
        try await mediaDownloader.data(for: media, groupIdHex: group.groupIdHex, appState: appState)
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

    /// Mirrors the resolved references for one message (from the timeline row,
    /// or from an upload result so a just-sent bubble renders before its row
    /// arrives) and refreshes that message's projection.
    @discardableResult
    private func replaceMediaReferences(_ references: [MediaAttachmentReferenceFfi], forMessageId messageIdHex: String) -> Bool {
        mediaProjections.replaceReferences(
            references,
            forMessageId: messageIdHex,
            itemResolver: { [unowned self] in visibleTimelineItem(forMessageId: $0) }
        )
    }

#if DEBUG
    @discardableResult
    func replaceMediaReferencesForTesting(_ references: [MediaAttachmentReferenceFfi], forMessageId messageIdHex: String) -> Bool {
        replaceMediaReferences(references, forMessageId: messageIdHex)
    }

    func installPendingMediaForTesting(rowId: String, items: [MessageMediaAttachment]) {
        mediaProjections.setPending(items, forRowId: rowId)
    }

    func pendingMediaForTesting(rowId: String) -> [MessageMediaAttachment]? {
        mediaProjections.pending(forRowId: rowId)
    }

    var mediaReferenceCountForTesting: Int {
        mediaProjections.referenceCountForTesting
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
                pendingHasStagedMedia: mediaProjections.pending(forRowId: key)?.isEmpty == false
            )
        }
        guard let match = matchingPendingMessages.min(by: { lhs, rhs in
            Self.pendingOutgoingMessage(lhs.value, isCloserTo: record, than: rhs.value)
        }) else { return false }
        transientTimelineItems[match.key] = nil
        mediaProjections.removePending(forRowId: match.key)
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
              status == .sending || status == .sent || status == .failed,
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

    func isDeleted(_ messageIdHex: String) -> Bool {
        _ = timelineProjectionGeneration
        return deletedProjections.contains(messageIdHex)
    }

    /// Rebuild the per-target reaction tallies, folding the local optimistic
    /// overlay and tombstoned un-reacts into the server summary. The aggregation
    /// lives in `reactionProjections`; this passes the current timeline deletes
    /// and local account id.
    @discardableResult
    private func recomputeReactions() -> Bool {
        reactionProjections.recompute(deletedMessageIds: deletedProjections.deletedMessageIds, me: myAccountId ?? "")
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
        let needsTimelineRefresh = Self.groupSnapshotNeedsTimelineTailRefresh(
            previousName: previousName,
            previousArchived: wasArchived,
            previousAdmins: previousAdmins,
            next: record
        )
        applyGroupMlsTrackedChanges {
            group = record
        }

        if needsTimelineRefresh {
            scheduleTimelineTailRefresh()
        }

        if !previousName.isEmpty && previousName != record.name {
            appState?.present(.success(L10n.string("Group renamed"), message: ProfileSanitizer.groupName(record.name)))
        }
        if record.archived && !wasArchived {
            appState?.present(.warning(L10n.string("Group archived")))
        } else if !record.archived && wasArchived {
            appState?.present(.success(L10n.string("Group unarchived")))
        }
        await refreshMembers()
    }

    /// Group-state subscriptions expose snapshots, not the source timeline
    /// record that caused the snapshot to change. If a visible group-system
    /// change arrives through this path, refresh Marmot's durable kind-1210
    /// timeline rows instead of synthesizing a local wall-clock row.
    nonisolated static func groupSnapshotNeedsTimelineTailRefresh(
        previousName: String,
        previousArchived: Bool,
        previousAdmins: Set<String>,
        next: AppGroupRecordFfi
    ) -> Bool {
        let nameChanged = !previousName.isEmpty && previousName != next.name
        let archiveStateChanged = next.archived != previousArchived
        let adminsChanged = Set(next.admins) != previousAdmins
        return nameChanged || archiveStateChanged || adminsChanged
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
            let detailsStart = ContinuousClock.now
            let details = try await appState.marmot.groupDetails(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )
            let state = try await appState.marmot.groupManagementState(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )
            logLoadDuration("group.details+management", since: detailsStart)
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
        let membersChanged = Self.groupMembersNeedTimelineTailRefresh(
            previousMemberIds: previousMemberIds,
            nextMemberIds: nextMemberIds
        )
        let adminsChanged = Set(details.group.admins) != previousAdmins
        if announceRosterChanges && membersChanged {
            appState?.present(.success(L10n.string("Group membership updated")))
        }
        group = details.group
        groupMemberDetails = details.members
        managementState = state
        members = nextMembers
        bumpGroupMlsRefreshGenerationIfNeeded(previousIdentity: previousIdentity)
        if adminsChanged || membersChanged {
            scheduleTimelineTailRefresh()
        }
    }

    /// Appends a session-only system row. Callers must pass a source timestamp;
    /// group-state snapshots without one should refresh Marmot's durable
    /// kind-1210 timeline records instead of using the client wall clock.
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
        guard let appState,
              appState.canUseRuntimeForForegroundWork,
              let accountRef = appState.activeAccountRef
        else { return }
        if await refreshGroupManagement(announceRosterChanges: true) {
            return
        }
        do {
            let next = try await appState.marmot.groupMembers(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )
            if Self.groupMembersNeedTimelineTailRefresh(
                previousMemberIds: members.map(\.memberIdHex),
                nextMemberIds: next.map(\.memberIdHex)
            ) {
                scheduleTimelineTailRefresh()
            }
            applyGroupMlsTrackedChanges {
                members = next
            }
        } catch {
            // Silent; the next subscription tick will retry.
        }
    }

    /// Member-detail snapshots also lack the causative group-system record, so
    /// membership diffs refresh the durable timeline instead of adding local
    /// roster rows with receipt-time ordering.
    nonisolated static func groupMembersNeedTimelineTailRefresh(
        previousMemberIds: [String],
        nextMemberIds: [String]
    ) -> Bool {
        nextMemberIds != previousMemberIds
    }

    // MARK: - Send

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSendMessages,
              !trimmed.isEmpty,
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
        mediaProjections.setPending(attachments.map(\.displayItem), forRowId: tempRowId)
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
                // Render the just-sent attachments immediately from the upload's
                // resolved references; the subscription row will mirror the same.
                if replaceMediaReferences(references, forMessageId: messageId) {
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
        let removedPendingMedia = mediaProjections.removePending(forRowId: "msg:\(tempId)")
        projectionChanged = (removedPendingMedia != nil) || projectionChanged
        projectionChanged = removeTimelineItem(id: "msg:\(tempId)") || projectionChanged
        if realId.isEmpty {
            // No server message id: the row stays transient under "msg:\(tempId)".
            // Restore the pending media we just removed so the just-sent
            // attachments keep rendering — without a real message id there is no
            // resolved-references entry to fall back on, so dropping this would
            // silently blank the bubble's images.
            if let removedPendingMedia {
                mediaProjections.setPending(removedPendingMedia, forRowId: rowId)
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

#if DEBUG
    func markFailedForTesting(tempId: String) {
        markFailed(tempId: tempId)
    }
#endif

    // MARK: - Reactions

    /// Tombstone a message we are allowed to delete. Optimistically marks it
    /// deleted, then publishes the delete payload (reverting on failure).
    func deleteMessage(_ message: AppMessageRecordFfi) async {
        guard let appState, let accountRef = appState.activeAccountRef,
              !message.messageIdHex.isEmpty,
              Self.canDeleteMessage(message, myAccountId: myAccountId, isSelfAdmin: isSelfAdmin)
        else { return }
        deletedProjections.insertOptimistic(message.messageIdHex)
        if deletedProjections.rebuild() {
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
            deletedProjections.removeOptimistic(message.messageIdHex)
            if deletedProjections.rebuild() {
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

    /// Clamp outbound message text to the protocol's max length (#54).
    nonisolated static func cappedOutgoingText(_ text: String) -> String {
        String(text.prefix(ProfileSanitizer.maxMessageLength))
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
        var clearedRemoval: ReactionRemoval?

        if alreadyMine {
            removal = ReactionRemoval(
                targetMessageIdHex: message.messageIdHex,
                emoji: emoji,
                sender: me
            )
            if let removal {
                reactionProjections.insertRemoval(removal)
            }
            // Un-react: drop my matching reaction record(s) for this target+emoji.
            // The real un-react publishes a kind-5 delete of the reaction event id.
            removedRecords = reactionProjections.removeMatchingRecords(
                target: message.messageIdHex,
                emoji: emoji,
                sender: me
            )
        } else {
            // Re-react: clear any pending optimistic un-react for this
            // target+emoji so the new add isn't immediately subtracted by a
            // stale removal in `recomputeReactions()` (#349). The removal is
            // tracked so failure can re-insert it.
            let pending = ReactionRemoval(
                targetMessageIdHex: message.messageIdHex,
                emoji: emoji,
                sender: me
            )
            if reactionProjections.removeRemoval(pending) {
                clearedRemoval = pending
            }
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
            reactionProjections.setRecord(synthetic, forKey: key)
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
            if let addedKey { reactionProjections.removeRecord(forKey: addedKey) }
            if let removal { reactionProjections.removeRemoval(removal) }
            if let clearedRemoval { reactionProjections.insertRemoval(clearedRemoval) }
            reactionProjections.restoreRecords(removedRecords)
            if recomputeReactions() {
                noteTimelineProjectionChanged()
            }
            Haptics.error()
            appState.present(.error(L10n.string("Reaction failed"), message: error.localizedDescription))
        }
    }
}

// MARK: - StreamWatcher timeline sink

extension ConversationViewModel: StreamWatcherTimelineSink {
    @discardableResult
    func streamUpsertTimelineItem(_ item: TimelineItem) -> Bool {
        upsertTimelineItem(item)
    }

    @discardableResult
    func streamRemoveTimelineItem(id: String) -> Bool {
        removeTimelineItem(id: id)
    }

    func streamTransientItem(id: String) -> TimelineItem? {
        transientTimelineItems[id]
    }

    func streamSetTransientItem(_ item: TimelineItem) {
        transientTimelineItems[item.id] = item
    }

    @discardableResult
    func streamRemoveTransientItem(id: String) -> Bool {
        transientTimelineItems.removeValue(forKey: id) != nil
    }

    @discardableResult
    func streamAppendDebugRow(_ item: TimelineItem) -> Bool {
        streamDebugTimelineItems[item.id] = item
        return upsertTimelineItem(item)
    }

    func streamNoteProjectionChanged() {
        noteTimelineProjectionChanged()
    }
}

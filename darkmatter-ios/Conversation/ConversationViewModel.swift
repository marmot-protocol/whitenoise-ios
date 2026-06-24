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

    /// The merged timeline, mirror, overlays, projection caches, and rebuild
    /// engine. The view model drives it (feeds pages, hands it optimistic rows)
    /// and reads projections back out. See `TimelineStore`.
    @ObservationIgnored let timelineStore: TimelineStore

    /// The send pipeline: in-flight guard, reply target, text/media send FFI.
    /// Hands optimistic rows to `timelineStore`. See `ComposerModel`.
    @ObservationIgnored let composer: ComposerModel

    // Timeline surface forwarded from `timelineStore` (observation propagates
    // through these computed reads because `timelineStore` is `@Observable`).
    var timeline: [TimelineItem] { timelineStore.timeline }
    var timelineProjectionGeneration: Int { timelineStore.timelineProjectionGeneration }
    var hasMoreBefore: Bool { timelineStore.hasMoreBefore }
    var hasMoreAfter: Bool { timelineStore.hasMoreAfter }
    var isLoading: Bool { timelineStore.isLoading }

    private(set) var group: AppGroupRecordFfi
    private(set) var members: [AppGroupMemberRecordFfi] = []
    private(set) var groupMemberDetails: [GroupMemberDetailsFfi] = []
    private(set) var groupMlsRefreshGeneration: UInt64 = 0
    private(set) var managementState: GroupManagementStateFfi?
    private(set) var isLoadingOlder = false
    private(set) var isLoadingNewer = false
    private(set) var error: String?
    private(set) var isMediaRecordsRefreshPending = false

    // Composer surface forwarded from `composer`.
    var sendInFlight: Bool { composer.sendInFlight }
    /// The message the composer is currently replying to (set by swipe / menu).
    var replyingTo: AppMessageRecordFfi? {
        get { composer.replyingTo }
        set { composer.replyingTo = newValue }
    }

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

    @ObservationIgnored private var timelineSubscription: TimelineMessagesSubscription?
    @ObservationIgnored private let mediaDownloader = ConversationMediaDownloader()
    // Lazy so its `[weak self]` loaded-window closure can capture a fully
    // initialized self; first touched on the post-start apply/mark paths.
    @ObservationIgnored private lazy var readMarker = ConversationReadMarker(
        groupIdHex: group.groupIdHex,
        maxMarkedReadMessageIds: Int(Self.timelinePageLimit) * 4,
        appState: appState,
        loadedMessageIds: { [weak timelineStore] in
            timelineStore?.loadedMessageIds ?? []
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
    /// `dropMatchingStreamPreview`) and writes its synthetic stream/debug rows into
    /// `timelineStore` through `StreamWatcherTimelineSink`. Constructed eagerly in
    /// `init` so `timelineStore.streamWatcher` is wired before the first page apply.
    @ObservationIgnored private let streamWatcher: StreamWatcher
#if DEBUG
    var streamTextEntryCountForTesting: Int { streamWatcher.streamTextEntryCountForTesting }
    var streamTextLengthEntryCountForTesting: Int { streamWatcher.streamTextLengthEntryCountForTesting }
    var scannedFinalizedMessageIdCountForTesting: Int { streamWatcher.scannedFinalizedMessageIdCountForTesting }
    var finalizedStreamIdCountForTesting: Int { streamWatcher.finalizedStreamIdCountForTesting }
    var markedReadMessageIdsForTesting: Set<String> { readMarker.markedReadMessageIdsForTesting }
    var mediaItemProjectionBuildCountForTesting: Int { timelineStore.mediaProjections.buildCountForTesting }

    func insertMarkedReadMessageIdsForTesting(_ messageIds: Set<String>) {
        readMarker.insertMarkedReadMessageIdsForTesting(messageIds)
    }

    func insertPendingReadMessageIdsForTesting(_ messageIds: [String]) {
        readMarker.insertPendingReadMessageIdsForTesting(messageIds)
    }
#endif

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

    /// Lazily resolves display inputs from the current group/member state.
    /// Call sites that need multiple title/avatar values should capture this
    /// once and pass it through rather than reading the property repeatedly.
    var groupDisplay: GroupDisplay.Resolved {
        GroupDisplay.resolve(
            group: group,
            otherMember: otherMember,
            memberCount: displayMemberCount
        )
    }

    var displayTitle: String {
        displayTitle(for: groupDisplay)
    }

    func displayTitle(for groupDisplay: GroupDisplay.Resolved) -> String {
        guard let appState else {
            if let name = groupDisplay.sanitizedName { return name }
            if let initialTitle = ProfileSanitizer.groupName(initialTitle) { return initialTitle }
            return IdentityFormatter.short(group.groupIdHex)
        }
        if members.isEmpty,
           groupMemberDetails.isEmpty,
           let initialTitle = ProfileSanitizer.groupName(initialTitle),
           groupDisplay.sanitizedName == nil {
            return initialTitle
        }
        return GroupDisplay.title(for: groupDisplay, appState: appState)
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

    // Timeline projection accessors — forwarded to `timelineStore`.
    func reactions(for messageIdHex: String) -> [ReactionTally] {
        timelineStore.reactions(for: messageIdHex)
    }

    /// All aggregated reaction tallies (full dict). Used by reaction tests.
    var reactions: [String: [ReactionTally]] { timelineStore.reactions }

#if DEBUG
    @discardableResult
    func forceFullReactionRecomputeForTesting() -> [String: [ReactionTally]] {
        timelineStore.forceFullReactionRecomputeForTesting()
    }
#endif

    func markdownDisplayBlocks(for item: TimelineItem) -> [MarkdownDisplayBlock]? {
        timelineStore.markdownDisplayBlocks(for: item)
    }

    func record(for messageIdHex: String) -> AppMessageRecordFfi? {
        timelineStore.record(for: messageIdHex)
    }

    func replyPreview(for record: AppMessageRecordFfi) -> (name: String, text: String)? {
        timelineStore.replyPreview(for: record)
    }

    func displayBody(of record: AppMessageRecordFfi) -> String {
        timelineStore.displayBody(of: record)
    }

    func isDeleted(_ messageIdHex: String) -> Bool {
        timelineStore.isDeleted(messageIdHex)
    }

    func mediaItems(for item: TimelineItem) -> [MessageMediaAttachment] {
        timelineStore.mediaItems(for: item)
    }

    func mediaItems(for record: AppMessageRecordFfi) -> [MessageMediaAttachment] {
        timelineStore.mediaItems(for: record)
    }

    // Timeline drive points — forwarded to `timelineStore`.
    func applyTimelinePage(_ page: TimelinePageFfi, placement: TimelinePagePlacement) {
        timelineStore.applyTimelinePage(page, placement: placement)
    }

    func applyTimelineSubscriptionUpdate(_ update: TimelineSubscriptionUpdateFfi) {
        timelineStore.applyTimelineSubscriptionUpdate(update)
    }

    func applyPendingOutgoingMessage(tempId: String, record: AppMessageRecordFfi) {
        timelineStore.applyPendingOutgoingMessage(tempId: tempId, record: record)
    }

    func confirmSent(tempId: String, record: AppMessageRecordFfi, messageId: String?) {
        timelineStore.confirmSent(tempId: tempId, record: record, messageId: messageId)
    }

    private func markFailed(tempId: String) {
        timelineStore.markFailed(tempId: tempId)
    }

    @discardableResult
    private func replaceMediaReferences(_ references: [MediaAttachmentReferenceFfi], forMessageId messageIdHex: String) -> Bool {
        timelineStore.replaceMediaReferences(references, forMessageId: messageIdHex)
    }

    private func appendSystemEvent(_ event: SystemEvent, timestamp: UInt64) {
        timelineStore.appendSystemEvent(event, timestamp: timestamp)
    }

    private func resetOptimisticState() {
        timelineStore.resetOptimisticState()
    }

    func refreshStreamingDebugPresentation() {
        timelineStore.refreshStreamingDebugPresentation()
    }

    func refreshProfileDependentTimelineProjections() {
        timelineStore.refreshProfileDependentTimelineProjections()
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
        self.timelineStore = TimelineStore(appState: appState, groupIdHex: group.groupIdHex)
        self.streamWatcher = StreamWatcher(appState: appState, groupIdHex: group.groupIdHex)
        self.composer = ComposerModel(appState: appState, groupIdHex: group.groupIdHex, timelineStore: timelineStore)
        streamWatcher.sink = timelineStore
        timelineStore.streamWatcher = streamWatcher
        timelineStore.mentionResolver = { [weak appState] entity in
            appState?.mentionDisplayName(for: entity)
        }
        timelineStore.readMarker = readMarker
        composer.canSendMessages = { [weak self] in self?.canSendMessages ?? false }
        composer.canSendMediaAttachments = { [weak self] in self?.canSendMediaAttachments ?? false }
        composer.onError = { [weak self] message in self?.error = message }
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
            timelineStore.setLoading(true)
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
        timelineStore.deletedProjections.insertOptimistic(deletedMessageIdHex)
        let reactionId = "optimistic-\(reactionTargetMessageIdHex)-\(emoji)"
        timelineStore.reactionProjections.setRecord(
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
        _ = timelineStore.deletedProjections.rebuild()
        _ = timelineStore.recomputeReactions()
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
                    let timelineSub = try await client.subscribeTimelineMessages(
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
                    self?.timelineStore.setLoading(false)
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
                    self?.timelineStore.setLoading(false)
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
                    timelineStore.setLoading(false)
                }
            } catch {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.initialTimelineSnapshotTask = nil
                if self.timeline.isEmpty {
                    self.timelineStore.setLoading(false)
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
                    let groupSub = try await client.subscribeGroupState(
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
                let client = try appState.currentMarmotClient()
                let next = try await client.groupMembers(
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
                timelineStore.setHasMoreBefore(false)
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
                timelineStore.setHasMoreAfter(false)
            }
        } catch {
            self.error = error.localizedDescription
        }
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

    static func messageId(in item: TimelineItem) -> String? {
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

#if DEBUG
    @discardableResult
    func replaceMediaReferencesForTesting(_ references: [MediaAttachmentReferenceFfi], forMessageId messageIdHex: String) -> Bool {
        replaceMediaReferences(references, forMessageId: messageIdHex)
    }

    func installPendingMediaForTesting(rowId: String, items: [MessageMediaAttachment]) {
        timelineStore.mediaProjections.setPending(items, forRowId: rowId)
    }

    func pendingMediaForTesting(rowId: String) -> [MessageMediaAttachment]? {
        timelineStore.mediaProjections.pending(forRowId: rowId)
    }

    var mediaReferenceCountForTesting: Int {
        timelineStore.mediaProjections.referenceCountForTesting
    }
#endif

    static func pendingOutgoingMessage(
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

    static func isMediaRecord(_ record: AppMessageRecordFfi) -> Bool {
        if case .media = MessageSemantics.classify(record) {
            return true
        }
        return false
    }

    static func pendingOutgoingMessage(
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

    static func pendingOutgoingRecordedAtDistance(_ item: TimelineItem, to recordedAt: UInt64) -> UInt64 {
        guard case .message(let pending, _) = item.kind else {
            return .max
        }
        return pending.recordedAt > recordedAt
            ? pending.recordedAt - recordedAt
            : recordedAt - pending.recordedAt
    }

    static func replyTargetMessageId(in record: AppMessageRecordFfi) -> String? {
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

    /// Pure per-target reaction tally: folds the server summary, optimistic
    /// un-react removals, and local optimistic reaction records (dropping
    /// tombstoned un-reacts) into the sorted tally for one message (#380). Lives
    /// here so `ConversationReactionProjectionCache` (full + incremental) and the
    /// tests share one implementation.
    nonisolated static func reactionTallies(
        for target: String,
        summary: TimelineReactionSummaryFfi?,
        optimisticRemovals: Set<ReactionRemoval>,
        optimisticRecords: [String: AppMessageRecordFfi],
        deletedMessageIds: Set<String>,
        me: String
    ) -> [ReactionTally] {
        var emojis: [String: Set<String>] = [:]

        if let summary {
            for reaction in summary.byEmoji where !reaction.emoji.isEmpty {
                emojis[reaction.emoji] = Set(reaction.senders)
            }
        }

        for removal in optimisticRemovals where removal.targetMessageIdHex == target {
            guard var senders = emojis[removal.emoji] else { continue }
            senders.remove(removal.sender)
            emojis[removal.emoji] = senders
        }

        // Local optimistic reaction records are kind-7 messages: emoji content,
        // target in the `e` tag. A reaction is dropped when its own event id has
        // been tombstoned by a delete (the un-react path).
        for record in optimisticRecords.values {
            guard case .reaction(let recordTarget) = MessageSemantics.classify(record),
                  recordTarget == target
            else { continue }
            if !record.messageIdHex.isEmpty, deletedMessageIds.contains(record.messageIdHex) {
                continue
            }
            let emoji = record.plaintext
            guard !emoji.isEmpty else { continue }
            var senders: Set<String> = emojis[emoji] ?? []
            senders.insert(record.sender)
            emojis[emoji] = senders
        }

        var tallies: [ReactionTally] = []
        for (emoji, senders) in emojis where !senders.isEmpty {
            tallies.append(ReactionTally(emoji: emoji, count: senders.count, mine: senders.contains(me)))
        }
        tallies.sort { lhs, rhs in
            lhs.count == rhs.count ? lhs.emoji < rhs.emoji : lhs.count > rhs.count
        }
        return tallies
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
            let client = try appState.currentMarmotClient()
            let detailsStart = ContinuousClock.now
            let details = try await client.groupDetails(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )
            let state = try await client.groupManagementState(
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
            let client = try appState.currentMarmotClient()
            let next = try await client.groupMembers(
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
        await composer.send(text)
    }

    func sendMedia(_ attachments: [MediaDraftAttachment], caption: String) async {
        await composer.sendMedia(attachments, caption: caption)
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
        timelineStore.deletedProjections.insertOptimistic(message.messageIdHex)
        if timelineStore.deletedProjections.rebuild() {
            timelineStore.noteProjectionChanged()
        }
        do {
            let client = try appState.currentMarmotClient()
            _ = try await client.deleteMessage(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex,
                targetMessageId: message.messageIdHex
            )
            Haptics.warning()
        } catch {
            timelineStore.deletedProjections.removeOptimistic(message.messageIdHex)
            if timelineStore.deletedProjections.rebuild() {
                timelineStore.noteProjectionChanged()
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
                timelineStore.reactionProjections.insertRemoval(removal)
            }
            // Un-react: drop my matching reaction record(s) for this target+emoji.
            // The real un-react publishes a kind-5 delete of the reaction event id.
            removedRecords = timelineStore.reactionProjections.removeMatchingRecords(
                target: message.messageIdHex,
                emoji: emoji,
                sender: me
            )
        } else {
            // Re-react: clear any pending optimistic un-react for this
            // target+emoji so the new add isn't immediately subtracted by a
            // stale removal in `timelineStore.recomputeReactions()` (#349). The removal is
            // tracked so failure can re-insert it.
            let pending = ReactionRemoval(
                targetMessageIdHex: message.messageIdHex,
                emoji: emoji,
                sender: me
            )
            if timelineStore.reactionProjections.removeRemoval(pending) {
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
            timelineStore.reactionProjections.setRecord(synthetic, forKey: key)
            addedKey = key
        }
        if timelineStore.recomputeReactions() {
            timelineStore.noteProjectionChanged()
        }
        Haptics.tap()

        do {
            let client = try appState.currentMarmotClient()
            if alreadyMine {
                _ = try await client.unreactFromMessage(
                    accountRef: accountRef,
                    groupIdHex: group.groupIdHex,
                    targetMessageId: message.messageIdHex
                )
            } else {
                _ = try await client.reactToMessage(
                    accountRef: accountRef,
                    groupIdHex: group.groupIdHex,
                    targetMessageId: message.messageIdHex,
                    emoji: emoji
                )
            }
        } catch {
            // Revert the optimistic change.
            if let addedKey { timelineStore.reactionProjections.removeRecord(forKey: addedKey) }
            if let removal { timelineStore.reactionProjections.removeRemoval(removal) }
            if let clearedRemoval { timelineStore.reactionProjections.insertRemoval(clearedRemoval) }
            timelineStore.reactionProjections.restoreRecords(removedRecords)
            if timelineStore.recomputeReactions() {
                timelineStore.noteProjectionChanged()
            }
            Haptics.error()
            appState.present(.error(L10n.string("Reaction failed"), message: error.localizedDescription))
        }
    }
}

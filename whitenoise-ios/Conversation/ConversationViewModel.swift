import Foundation
import Observation
import MarmotKit
import os

nonisolated enum DurableConvergenceRetryAction: Equatable {
    case retry
    case refreshBeforeRetry
    case stop
}

nonisolated enum DurableConvergenceRetryPolicy {
    static func action(for error: Error) -> DurableConvergenceRetryAction {
        guard let marmotError = error as? MarmotKitError else { return .retry }
        if marmotError.isGroupUnrecoverableRepairRequired { return .stop }
        if marmotError.isAccountWorkerResponseTimedOut { return .refreshBeforeRetry }
        return .retry
    }
}

enum ConversationInviteAction: Equatable {
    case accepting
    case declining
}

enum AgentStreamWatchAdmission {
    static func canStart(
        streamIdHex: String?,
        activeStreamIds: Set<String>,
        inFlightStreamIds: Set<String> = [],
        latestStreamWatchInFlight: Bool
    ) -> Bool {
        if let streamIdHex {
            return !activeStreamIds.contains(streamIdHex) && !inFlightStreamIds.contains(streamIdHex)
        }
        return !latestStreamWatchInFlight
    }

    /// Post-await install decision. The epoch check is what makes `cancelAll()`
    /// stick: a watch suspended on the subscription open when the session was
    /// cancelled must not install into the restarted session's dictionaries —
    /// the emptied dictionaries alone would wave it through.
    static func shouldInstall(
        sessionEpoch: Int,
        currentSessionEpoch: Int,
        streamId: String,
        activeStreamIds: Set<String>,
        finalizedStreamIds: Set<String>
    ) -> Bool {
        sessionEpoch == currentSessionEpoch
            && !activeStreamIds.contains(streamId)
            && !finalizedStreamIds.contains(streamId)
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

nonisolated struct ConversationGroupRosterProjection: Equatable {
    let memberRecords: [AppGroupMemberRecordFfi]
    let memberDetails: [GroupMemberDetailsFfi]
    let adminIdsHex: [String]
    let selfMembership: SelfMembershipFfi
    let isUnrecoverable: Bool
    let isDisbanded: Bool
    let revision: UInt64

    init(roster: GroupRosterFfi) {
        memberDetails = roster.members
        memberRecords = roster.members.map {
            AppGroupMemberRecordFfi(
                memberIdHex: $0.memberIdHex,
                account: $0.account,
                local: $0.local
            )
        }
        adminIdsHex = roster.members.filter(\.isAdmin).map(\.memberIdHex)
        selfMembership = roster.selfMembership
        isUnrecoverable = roster.lifecycleState == .unrecoverable
        isDisbanded = roster.lifecycleState == .disbanded
        revision = roster.rosterRevision
    }
}

/// Owns the live state of a single conversation: the merged timeline of
/// message bubbles + system events, aggregated reactions, the group roster,
/// the in-progress reply, and the send pipeline.
@Observable
@MainActor
final class ConversationViewModel {

    typealias DeleteMessageOperation = @MainActor (
        _ client: MarmotClient,
        _ accountRef: String,
        _ groupIdHex: String,
        _ messageIdHex: String
    ) async throws -> SendSummaryFfi

    nonisolated struct DurableRetryOperations {
        let catchUp: @MainActor (MarmotClient) async throws -> Void
        let converge: @MainActor (MarmotClient, String, String) async throws -> SendSummaryFfi
        let sleep: @MainActor (UInt64) async throws -> Void
        let refresh: @MainActor (ConversationViewModel) async -> Void

        static let live = DurableRetryOperations(
            catchUp: { try await $0.catchUpAccounts() },
            converge: { client, accountRef, groupIdHex in
                try await client.retryGroupConvergence(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex
                )
            },
            sleep: { try await Task.sleep(nanoseconds: $0) },
            refresh: { viewModel in await viewModel.refreshTimelineTail() }
        )
    }

    /// One emoji's tally on a target message.
    nonisolated struct ReactionTally: Identifiable, Hashable {
        let emoji: String
        let count: Int
        let mine: Bool
        var id: String { emoji }
    }

    /// Sender-level reaction data for one message. The bubble uses `tallies`,
    /// while the reaction details sheet groups the same data by user. Keeping
    /// both projections on this one model prevents optimistic react/un-react
    /// state from disagreeing between the bubble and the sheet.
    nonisolated struct ReactionDetails: Hashable {
        struct EmojiGroup: Identifiable, Hashable {
            let emoji: String
            let senders: [String]
            let mine: Bool

            var id: String { emoji }
            var count: Int { senders.count }
        }

        struct User: Identifiable, Hashable {
            let sender: String
            let emojis: [String]

            var id: String { sender }
        }

        let groups: [EmojiGroup]

        var tallies: [ReactionTally] {
            groups.map { group in
                ReactionTally(emoji: group.emoji, count: group.count, mine: group.mine)
            }
        }

        var totalReactionCount: Int {
            groups.reduce(0) { $0 + $1.count }
        }

        func users(filteredBy emoji: String?) -> [User] {
            var emojisBySender: [String: [String]] = [:]

            for group in groups where emoji == nil || group.emoji == emoji {
                for sender in group.senders {
                    emojisBySender[sender, default: []].append(group.emoji)
                }
            }

            return emojisBySender
                .map { User(sender: $0.key, emojis: $0.value) }
                .sorted { $0.sender < $1.sender }
        }
    }

    /// The merged timeline, mirror, overlays, projection caches, and rebuild
    /// engine. The view model drives it (feeds pages, hands it optimistic rows)
    /// and reads projections back out. See `TimelineStore`.
    @ObservationIgnored let timelineStore: TimelineStore

    /// The send pipeline: in-flight guard, reply target, text/media send FFI.
    /// Hands optimistic rows to `timelineStore`. See `ComposerModel`.
    @ObservationIgnored let composer: ComposerModel

    /// In-conversation message search: query, ordered matches over the loaded
    /// window, current-match cursor, and the budgeted older-history step.
    @ObservationIgnored let search: ConversationSearchModel

    // Timeline surface forwarded from `timelineStore` (observation propagates
    // through these computed reads because `timelineStore` is `@Observable`).
    var timeline: [TimelineItem] { timelineStore.timeline }
    var timelineProjectionGeneration: Int { timelineStore.timelineProjectionGeneration }
    var hasMoreBefore: Bool { timelineStore.hasMoreBefore }
    var hasMoreAfter: Bool { timelineStore.hasMoreAfter }
    var isLoading: Bool { timelineStore.isLoading }
    var canLoadOlderTimelinePage: Bool {
        hasMoreBefore && !isLoadingOlder && timelineSubscription != nil
    }

    let recovery = GroupRecoveryModel()

    private(set) var group: AppGroupRecordFfi
    private(set) var leaveRequestPending: Bool
    private(set) var members: [AppGroupMemberRecordFfi] = []
    private(set) var groupMemberDetails: [GroupMemberDetailsFfi] = []
    private(set) var mentionRosterResolution: ComposerMentionRosterResolution = .unresolved
    private(set) var groupMlsRefreshGeneration: UInt64 = 0
    private(set) var groupRosterRevision: UInt64?
    private(set) var managementState: GroupManagementStateFfi?
    private(set) var isLoadingOlder = false
    private(set) var isLoadingNewer = false
    private(set) var error: String?
    private(set) var inviteActionInFlight: ConversationInviteAction?

    // Composer surface forwarded from `composer`.
    var sendInFlight: Bool { composer.sendInFlight }
    /// The message the composer is currently replying to (set by swipe / menu).
    var replyingTo: AppMessageRecordFfi? {
        get { composer.replyingTo }
        set { composer.replyingTo = newValue }
    }
    var replyTargetMessageIdHex: String? { composer.replyTargetMessageIdHex }

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
    @ObservationIgnored private let daySectionProjections = ConversationDaySectionProjectionCache()
    @ObservationIgnored private let deleteMessageOperation: DeleteMessageOperation
    @ObservationIgnored private let durableRetryOperations: DurableRetryOperations
    // Lazy so its `[weak self]` loaded-window closure can capture a fully
    // initialized self; first touched on the post-start apply/mark paths.
    @ObservationIgnored private lazy var readMarker = ConversationReadMarker(
        groupIdHex: group.groupIdHex,
        maxMarkedReadMessageIds: Int(Self.timelinePageLimit) * 4,
        appState: appState,
        loadedMessageIds: { [weak timelineStore] in
            timelineStore?.loadedMessageIdsInTimelineOrder ?? []
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
    @ObservationIgnored var acceptGroupInviteForTesting: (@MainActor (String, String) async throws -> AppGroupRecordFfi)?
    @ObservationIgnored var refreshInviteStateForTesting: (@MainActor () async -> Bool)?
    @ObservationIgnored var declineGroupInviteForTesting: (@MainActor (String, String) async throws -> GroupInviteDeclineResultFfi)?

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
        subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.whitenoise",
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
            if let initialTitle = ContentSanitizer.groupName(initialTitle) { return initialTitle }
            return IdentityFormatter.short(group.groupIdHex)
        }
        if members.isEmpty,
           groupMemberDetails.isEmpty,
           let initialTitle = ContentSanitizer.groupName(initialTitle),
           groupDisplay.sanitizedName == nil {
            return initialTitle
        }
        return GroupDisplay.title(for: groupDisplay, appState: appState)
    }

    var displaySubtitle: String? {
        // A DM header shows just the contact's name — no member count.
        if groupDisplay.isDirectMessage { return nil }
        let memberCount = displayMemberCount
        if memberCount == 0 { return L10n.string("Just you") }
        return L10n.plural("%lld members", Int64(memberCount))
    }

    /// Mirrors Android's empty-group affordance: only a confirmed sole-member
    /// admin sees the invite CTA, never a roster that simply has not loaded yet.
    var canInviteFromEmptyGroup: Bool {
        EmptyGroupConversationPresentation.canInvite(
            isSelfMember: group.selfMembership == .member,
            isSelfAdmin: isSelfAdmin,
            membersLoaded: !groupMemberDetails.isEmpty,
            memberCount: groupMemberDetails.count,
            onlyMemberIsSelf: groupMemberDetails.first?.isSelf == true
        )
    }

    /// The other participant's npub in a DM, so the conversation header can open
    /// their profile. `nil` for groups or before member details have loaded.
    var directMessageCounterpartNpub: String? {
        guard groupDisplay.isDirectMessage else { return nil }
        return groupMemberDetails.first { !$0.isSelf }?.npub
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

    var isGroupDisbanding: Bool {
        group.disbanding || managementState?.disbanding == true
    }

    var isGroupDisbanded: Bool {
        group.disbanded || managementState?.lifecycleState == .disbanded
    }

    var isGroupDisbandingOrDisbanded: Bool {
        isGroupDisbanding || isGroupDisbanded
    }

    var isGroupUnrecoverable: Bool {
        group.unrecoverable || managementState?.lifecycleState == .unrecoverable
    }

    var canSendMessages: Bool {
        guard !group.pendingConfirmation else { return false }
        guard !leaveRequestPending else { return false }
        guard !isGroupDisbandingOrDisbanded else { return false }
        guard !isGroupUnrecoverable else { return false }
        return GroupManagementPresentation.isActiveMember(
            state: managementState,
            members: members,
            groupMemberDetails: groupMemberDetails,
            myAccountId: myAccountId,
            fallbackSelfMembership: group.selfMembership
        )
    }

    var inactiveGroupMessage: String? {
        guard !canSendMessages else { return nil }
        if isGroupDisbanded {
            return GroupManagementPresentation.disbandedComposerMessage
        }
        if isGroupDisbanding {
            return GroupManagementPresentation.disbandingComposerMessage
        }
        if leaveRequestPending {
            return GroupManagementPresentation.leavingGroupComposerMessage
        }
        if isGroupUnrecoverable {
            return L10n.string("This conversation needs to be rejoined before you can send messages.")
        }
        if group.selfMembership == .left {
            return GroupManagementPresentation.leftGroupComposerMessage
        }
        return GroupManagementPresentation.inactiveGroupComposerMessage
    }

    var canSendMediaAttachments: Bool {
        canSendMessages
            && group.encryptedMedia.required
            && MessageSemantics.supportsEncryptedMediaVersion(group.encryptedMedia.version)
            && group.encryptedMedia.allowedLocatorKinds.contains("blossom-v1")
    }

    var hasPendingInvite: Bool {
        group.pendingConfirmation
    }

    var inviterAccountIdHex: String? {
        ConversationInvitePresentation.normalizedInviterAccountId(group.welcomerAccountIdHex)
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

    func reactionDetails(for messageIdHex: String) -> ReactionDetails {
        timelineStore.reactionDetails(for: messageIdHex)
    }

    func messageClusterPresentation(for item: TimelineItem) -> MessageClusterPresentation {
        timelineStore.messageClusterPresentation(for: item)
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

    func groupSystemDisplayText(for record: AppMessageRecordFfi) -> String? {
        timelineStore.groupSystemDisplayText(for: record)
    }

    func record(for messageIdHex: String) -> AppMessageRecordFfi? {
        timelineStore.record(for: messageIdHex)
    }

    func records(forRowFrameKeys rowFrameKeys: Set<String>) -> [AppMessageRecordFfi] {
        timelineStore.records(forRowFrameKeys: rowFrameKeys)
    }

    func replyPreview(for record: AppMessageRecordFfi) -> ConversationReplyPreview? {
        timelineStore.replyPreview(for: record)
    }

    func replyTargetMessageId(for record: AppMessageRecordFfi) -> String? {
        timelineStore.replyTargetMessageId(for: record)
    }

    func displayBody(of record: AppMessageRecordFfi) -> String {
        timelineStore.displayBody(of: record)
    }

    func composerMentionDraftState(for draft: String) -> ComposerMentionDraftState {
        mentionController.captureDraftState(for: draft)
    }

    func restoreComposerMentionDraftState(_ state: ComposerMentionDraftState) {
        mentionController.restoreDraftState(state)
    }

    func restoreReplyTarget(messageIdHex: String?) {
        composer.restoreReplyTarget(
            messageIdHex: messageIdHex,
            record: messageIdHex.flatMap { record(for: $0) }
        )
    }

    func editingText(for message: AppMessageRecordFfi) -> String {
        mentionController.prepareEditingText(
            message.plaintext,
            appState: appState,
            members: members,
            groupMemberDetails: groupMemberDetails,
            rosterGeneration: groupMlsRefreshGeneration
        )
    }

    func preparedComposerText(_ text: String) -> String? {
        mentionController.outgoingText(
            for: text,
            appState: appState,
            members: members,
            groupMemberDetails: groupMemberDetails,
            rosterGeneration: groupMlsRefreshGeneration,
            rosterResolution: mentionRosterResolution
        )
    }

    func consumeComposerText(_ text: String) -> String? {
        let outgoing = preparedComposerText(text)
        mentionController.clearSelections()
        return outgoing
    }

    func isDeleted(_ messageIdHex: String) -> Bool {
        timelineStore.isDeleted(messageIdHex)
    }

    func isEdited(_ messageIdHex: String) -> Bool {
        timelineStore.isEdited(messageIdHex)
    }

    func hasEditHistory(_ messageIdHex: String) -> Bool {
        timelineStore.hasEditHistory(messageIdHex)
    }

    func editHistory(for messageIdHex: String) -> [EditHistoryPresentation.Row] {
        timelineStore.editHistory(for: messageIdHex)
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
        leaveRequestPending: Bool = false,
        onChatListRowUpdated: ((ChatListRowFfi) -> Void)? = nil,
        deleteMessageOperation: @escaping DeleteMessageOperation = { client, accountRef, groupIdHex, messageIdHex in
            try await client.deleteMessage(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                targetMessageId: messageIdHex
            )
        },
        durableRetryOperations: DurableRetryOperations = .live
    ) {
        self.appState = appState
        self.group = group
        self.leaveRequestPending = leaveRequestPending || group.leaveRequestPending
        self.initialTitle = initialTitle
        self.initialOtherMember = initialOtherMember
        self.initialMemberCount = initialMemberCount
        self.onChatListRowUpdated = onChatListRowUpdated
        self.deleteMessageOperation = deleteMessageOperation
        self.durableRetryOperations = durableRetryOperations
        let hiddenMessageIds = appState.activeAccountRef.map {
            MessageHideStore.hiddenMessageIds(accountRef: $0, groupIdHex: group.groupIdHex)
        } ?? []
        self.timelineStore = TimelineStore(
            appState: appState,
            groupIdHex: group.groupIdHex,
            hiddenMessageIds: hiddenMessageIds
        )
        self.streamWatcher = StreamWatcher(appState: appState, groupIdHex: group.groupIdHex)
        self.composer = ComposerModel(appState: appState, groupIdHex: group.groupIdHex, timelineStore: timelineStore)
        self.search = ConversationSearchModel()
        self.search.analytics = appState.productAnalytics
        search.entriesProvider = { [weak self] in self?.searchableTimelineEntries() ?? [] }
        search.hasMoreBefore = { [weak self] in self?.hasMoreBefore ?? false }
        search.loadOlderPage = { [weak self] in await self?.loadOlderTimelinePage() }
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
        if timeline.isEmpty {
            timelineStore.setLoading(true)
        }
        guard case .loadLocalSnapshot(startLiveWork: true) = startDecision else {
            startInitialTimelineSnapshot(accountRef: accountRef)
            return
        }
        startLiveTimeline(accountRef: accountRef)
        startLiveGroupState(accountRef: accountRef)
        startDeferredGroupDetails(accountRef: accountRef)
        startDeferredReadState()
    }

    func prepareForLocalGroupRemoval() {
        stopLiveSubscriptions()
    }

    func markLeaveRequested() {
        leaveRequestPending = true
        var updatedGroup = group
        updatedGroup.leaveRequestPending = true
        updatedGroup.leaveRequestedAtMs = updatedGroup.leaveRequestedAtMs
            ?? UInt64(Date().timeIntervalSince1970 * 1_000)
        group = updatedGroup
        if var state = managementState {
            state.canLeave = false
            state.leaveRequestPending = true
            state.leaveRequestedAtMs = updatedGroup.leaveRequestedAtMs
            managementState = state
        }
    }

    func markSelfLeft() {
        markLeaveRequested()
        let previousIdentity = groupMlsRefreshIdentity
        var updatedGroup = group
        updatedGroup.selfMembership = .left
        group = updatedGroup
        if let state = managementState {
            managementState = GroupManagementStateFfi(
                myAccountIdHex: state.myAccountIdHex,
                isSelfAdmin: false,
                isLastAdmin: false,
                canInvite: false,
                canLeave: false,
                requiresSelfDemoteBeforeLeave: false,
                leaveRequestPending: true,
                leaveRequestedAtMs: group.leaveRequestedAtMs,
                memberActions: state.memberActions.filter { !$0.isSelf }
            )
        }
        bumpGroupMlsRefreshGenerationIfNeeded(previousIdentity: previousIdentity)
    }

    func markDisbandRequested(_ request: DisbandRequestFfi) {
        var updatedGroup = group
        updatedGroup.disbanding = true
        updatedGroup.disbandRequest = request
        group = updatedGroup
        if var state = managementState {
            state.disbanding = true
            state.canInvite = false
            state.canLeave = false
            state.requiresSelfDemoteBeforeLeave = false
            state.canEnableDisbanding = false
            state.canDisband = false
            state.disbandRequest = request
            managementState = state
        }
        scheduleTimelineTailRefresh()
    }

    func clearDisbandFailure() {
        var updatedGroup = group
        updatedGroup.disbanding = false
        updatedGroup.disbandRequest = nil
        group = updatedGroup
        if var state = managementState {
            state.disbanding = false
            state.disbandRequest = nil
            managementState = state
        }
    }

    func markVisibleMessagesRead(_ records: [AppMessageRecordFfi]) {
        for record in records {
            readMarker.markReadIfVisible(
                record,
                isDeleted: isDeleted(record.messageIdHex)
            )
        }
    }

    private func pruneMarkedReadMessageIds(force: Bool = false) {
        readMarker.pruneMarkedReadMessageIds(force: force)
    }

    func deleteCapability(for message: AppMessageRecordFfi) -> MessageDeleteCapability {
        guard let canonical = canonicalDeleteRecord(for: message) else {
            return .unavailable
        }
        let hasActiveAccount = appState?.activeAccountRef?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty == false
        return MessageDeletePolicy.capability(
            isDirectMessage: groupDisplay.isDirectMessage,
            isMine: isMessageMine(canonical),
            isSelfAdmin: isSelfAdmin,
            localDeleteSupported: hasActiveAccount,
            remoteDeleteSupported: hasActiveAccount && canSendMessages,
            isDeleted: isDeleted(canonical.messageIdHex),
            isHidden: timelineStore.isHidden(canonical.messageIdHex)
        )
    }

    private func canonicalDeleteRecord(for message: AppMessageRecordFfi) -> AppMessageRecordFfi? {
        // Message ids are 32-byte nostr event ids and stay strictly
        // validated; group ids are opaque engine hex (16 bytes today) and
        // must not be forced through the 32-byte gate.
        guard let messageId = Hex.normalized32Bytes(message.messageIdHex),
              let canonical = timelineStore.record(for: messageId),
              let canonicalGroupId = Hex.normalizedGroupIdHex(canonical.groupIdHex),
              let currentGroupId = Hex.normalizedGroupIdHex(group.groupIdHex),
              canonicalGroupId == currentGroupId
        else { return nil }
        return canonical
    }

    /// Committed-but-undelivered rows retry via group convergence (any
    /// content). A failed transient row (nothing committed) retries only when
    /// it's a text send — media bytes aren't retained for re-upload.
    func canRetryFailedSend(rowId: String) -> Bool {
        if timelineStore.undeliveredDurableMessageId(rowId: rowId) != nil { return true }
        guard let record = timelineStore.failedTransientRecord(rowId: rowId) else { return false }
        return !record.plaintext.isEmpty
            && !timelineStore.failedTransientRowHasStagedMedia(rowId: rowId)
            && record.tags.allSatisfy { $0.values.first != "_media_pending" }
    }

    /// Failed transient rows are dropped outright; a committed undelivered
    /// row is part of group history, so its Delete hides it locally instead.
    func canDiscardFailedSend(rowId: String) -> Bool {
        timelineStore.failedTransientRecord(rowId: rowId) != nil
            || timelineStore.undeliveredDurableMessageId(rowId: rowId) != nil
    }

    func retryFailedSend(rowId: String) async {
        if let messageIdHex = timelineStore.undeliveredDurableMessageId(rowId: rowId) {
            guard MediaAutoDownloadStore.shared.isOnline else {
                composer.onError(L10n.string("You're offline. Try again once you're connected."))
                return
            }
            guard let appState, let accountRef = appState.activeAccountRef else { return }
            guard let client = try? appState.currentMarmotClient() else {
                composer.onError(L10n.string("Send failed"))
                return
            }
            guard let retryState = timelineStore.durableRowStatusBeforeRetry(
                messageIdHex: messageIdHex
            ) else { return }
            // Immediate feedback: the retry can legitimately take several
            // seconds while relays finish reconnecting after the network
            // change that stranded the message in the first place.
            timelineStore.setDurableRowStatus(.sending, messageIdHex: messageIdHex)
            defer {
                timelineStore.restoreDurableRowStatusAfterRetry(
                    retryState,
                    messageIdHex: messageIdHex
                )
            }
            // Relay recovery is otherwise tied to app-foreground activation,
            // and a retry after a network change is exactly when the pool is
            // still down — pump the account workers first, like foregrounding
            // does.
            try? await durableRetryOperations.catchUp(client)
            guard !Task.isCancelled else { return }
            // Re-drives the already-committed message to the relays —
            // re-sending the text would mint a duplicate bubble. A publish
            // into a still-reconnecting relay pool THROWS, so each attempt
            // catches and the window keeps retrying past those errors.
            var delivered = false
            var lastFailure: String?
            retryLoop: for attempt in 0..<6 {
                if attempt > 0 {
                    do {
                        try await durableRetryOperations.sleep(2_500_000_000)
                    } catch {
                        return
                    }
                }
                do {
                    let summary = try await durableRetryOperations.converge(
                        client,
                        accountRef,
                        group.groupIdHex
                    )
                    if summary.published > 0 {
                        delivered = true
                        break
                    }
                    lastFailure = nil
                } catch is CancellationError {
                    return
                } catch {
                    lastFailure = UserFacingError.present(
                        title: L10n.string("Send failed"),
                        error: error
                    ).message
                    switch DurableConvergenceRetryPolicy.action(for: error) {
                    case .retry:
                        continue
                    case .refreshBeforeRetry:
                        // The worker may have completed. Pull authoritative
                        // state before another idempotent convergence attempt.
                        await durableRetryOperations.refresh(self)
                        guard !Task.isCancelled else { return }
                        if timelineStore.undeliveredDurableMessageId(rowId: rowId) == nil {
                            delivered = true
                            break retryLoop
                        }
                    case .stop:
                        // Repair-required groups need another member to
                        // re-admit this device; retries cannot make progress.
                        break retryLoop
                    }
                }
            }
            // The subscription may not push the healed row; pull it so the
            // bubble flips without leaving the chat.
            await durableRetryOperations.refresh(self)
            guard !Task.isCancelled else { return }
            if timelineStore.undeliveredDurableMessageId(rowId: rowId) != nil {
                if delivered {
                    // The engine acked the publish but the healed row sits
                    // outside the refreshed tail page — trust the ack.
                    timelineStore.markDurableRowDelivered(messageIdHex: messageIdHex)
                } else {
                    composer.onError(lastFailure ?? L10n.string("Send failed"))
                }
            }
            return
        }
        await composer.retryFailedTextSend(rowId: rowId)
    }

    func discardFailedSend(rowId: String) {
        if let messageIdHex = timelineStore.undeliveredDurableMessageId(rowId: rowId),
           let record = timelineStore.durableRecord(messageIdHex: messageIdHex) {
            Task { await deleteMessageForMe(record) }
            return
        }
        timelineStore.discardTransientRow(rowId: rowId)
    }

    func isMessageMine(_ message: AppMessageRecordFfi) -> Bool {
        guard let myAccountId, !myAccountId.isEmpty else { return false }
        return message.sender.caseInsensitiveCompare(myAccountId) == .orderedSame
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
        timelineStore.visibilityPerformance.reset()
        recovery.invalidate()
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
            var startedStandaloneSnapshotFallback = false
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
                    if !startedStandaloneSnapshotFallback,
                       self?.timeline.isEmpty == true {
                        startedStandaloneSnapshotFallback = true
                        self?.startInitialTimelineSnapshot(accountRef: accountRef)
                    }
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
                    await self?.recovery.refresh(using: appState, groupID: groupIdHex)
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
                let roster = try await client.groupRoster(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex
                )
                self.applyGroupRoster(roster)
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

    /// Expiration prunes delete records locally without a subscription
    /// broadcast, so the newest page is reapplied with `.window` placement:
    /// unlike a tail refresh, that path evicts loaded records that no longer
    /// exist in storage when the page boundaries confirm the loss.
    func refreshTimelineWindowAfterLocalPrune() async {
        guard let request = timelineTailRefreshRequest() else { return }
        do {
            let page = try await Self.timelineTailPage(for: request)
            guard !Task.isCancelled,
                  appState?.activeAccountRef == request.accountRef,
                  group.groupIdHex == request.groupIdHex
            else { return }
            applyTimelinePage(page, placement: .window)
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
            search.notePagingFailure()
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
            sourceEpoch: record.sourceEpoch,
            retentionSeconds: record.retentionSeconds,
            retentionExpiresAt: record.retentionExpiresAt,
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

        func appendDrainingDeferredReplies(from root: TimelineItem) {
            var stack = [root]
            while let item = stack.popLast() {
                ordered.append(item)
                guard let messageId = Self.messageId(in: item) else { continue }
                emittedMessageIds.insert(messageId)

                let deferredReplies = deferredRepliesByParentId.removeValue(forKey: messageId) ?? []
                for deferred in deferredReplies.reversed() {
                    guard let deferredId = Self.messageId(in: deferred),
                          !emittedMessageIds.contains(deferredId)
                    else { continue }
                    stack.append(deferred)
                }
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
                appendDrainingDeferredReplies(from: item)
                continue
            }

            deferredRepliesByParentId[parentId, default: []].append(item)
        }

        if !deferredRepliesByParentId.isEmpty {
            for item in items {
                guard let messageId = Self.messageId(in: item),
                      !emittedMessageIds.contains(messageId)
                else { continue }
                appendDrainingDeferredReplies(from: item)
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

    @ObservationIgnored private var searchEntriesCache: (generation: Int, entries: [ConversationSearchEntry])?

    /// Haystack rows for in-conversation search, memoized by
    /// `timelineProjectionGeneration`. Search recomputes matches on every
    /// keystroke, and the flattened haystack only changes when the projection
    /// does, so caching it avoids re-flattening every previewable row (a
    /// budgeted markdown AST walk) on the typing hot path.
    private func searchableTimelineEntries() -> [ConversationSearchEntry] {
        let generation = timelineProjectionGeneration
        if let cache = searchEntriesCache, cache.generation == generation {
            return cache.entries
        }
        let entries = computeSearchableTimelineEntries()
        searchEntriesCache = (generation, entries)
        return entries
    }

    func timelineDaySections(
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> [TimelineDaySection] {
        daySectionProjections.sections(
            for: timeline,
            generation: timelineProjectionGeneration,
            calendar: calendar,
            locale: locale
        )
    }

    func agentEventDisplay(for item: TimelineItem) -> AgentEventPresentation.Display? {
        timelineStore.agentEventDisplay(for: item)
    }

    /// Confirmed, previewable, non-deleted message rows flattened to plain text
    /// through the budgeted preview path (`MessagePreview.body` →
    /// `MarkdownPlainText.flatten`).
    private func computeSearchableTimelineEntries() -> [ConversationSearchEntry] {
        timeline.compactMap { item in
            guard case .message(let record, _) = item.kind,
                  !record.messageIdHex.isEmpty,
                  MessagePreview.isPreviewable(record),
                  !isDeleted(record.messageIdHex)
            else { return nil }
            let text = displayBody(of: record)
            guard !text.isEmpty else { return nil }
            return ConversationSearchEntry(
                itemId: item.id,
                messageIdHex: record.messageIdHex,
                text: text
            )
        }
    }

    func data(for media: MessageMediaAttachment) async throws -> Data {
        try await mediaDownloader.data(for: media, groupIdHex: group.groupIdHex, appState: appState)
    }

#if DEBUG
    var markdownProjectionBuildCountForTesting: Int {
        timelineStore.markdownProjectionBuildCountForTesting
    }

    var groupSystemProjectionBuildCountForTesting: Int {
        timelineStore.groupSystemProjectionBuildCountForTesting
    }

    var agentEventProjectionBuildCountForTesting: Int {
        timelineStore.agentEventProjectionBuildCountForTesting
    }

    var reactionTargetCollectionCountForTesting: Int {
        timelineStore.reactionTargetCollectionCountForTesting
    }

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

    var timelineRebuildCountForTesting: Int {
        timelineStore.timelineRebuildCountForTesting
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
            sourceEpoch: r.message.sourceEpoch,
            retentionSeconds: r.message.retentionSeconds,
            retentionExpiresAt: r.message.retentionExpiresAt,
            recordedAt: r.message.recordedAt > 0 ? r.message.recordedAt : now,
            receivedAt: r.message.receivedAt > 0 ? r.message.receivedAt : now
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
        reactionDetails(
            for: target,
            summary: summary,
            optimisticRemovals: optimisticRemovals,
            optimisticRecords: optimisticRecords,
            deletedMessageIds: deletedMessageIds,
            me: me
        ).tallies
    }

    /// Marmot's un-react command removes every active reaction from this
    /// account on the target message, regardless of which emoji was tapped.
    nonisolated static func reactionRemovalsForUnreact(
        target: String,
        tallies: [ReactionTally],
        sender: String
    ) -> Set<ReactionRemoval> {
        guard !target.isEmpty, !sender.isEmpty else { return [] }
        return Set(tallies.compactMap { tally in
            guard tally.mine else { return nil }
            return ReactionRemoval(
                targetMessageIdHex: target,
                emoji: tally.emoji,
                sender: sender
            )
        })
    }

    /// Sender-level counterpart to `reactionTallies`. This is the canonical
    /// fold of Marmot's authenticated summary and the local optimistic overlay.
    nonisolated static func reactionDetails(
        for target: String,
        summary: TimelineReactionSummaryFfi?,
        optimisticRemovals: Set<ReactionRemoval>,
        optimisticRecords: [String: AppMessageRecordFfi],
        deletedMessageIds: Set<String>,
        me: String
    ) -> ReactionDetails {
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

        var groups: [ReactionDetails.EmojiGroup] = []
        for (emoji, senders) in emojis where !senders.isEmpty {
            groups.append(ReactionDetails.EmojiGroup(
                emoji: emoji,
                senders: senders.sorted(),
                mine: senders.contains(me)
            ))
        }
        groups.sort { lhs, rhs in
            lhs.count == rhs.count ? lhs.emoji < rhs.emoji : lhs.count > rhs.count
        }
        return ReactionDetails(groups: groups)
    }

    private func applyGroupUpdate(_ record: AppGroupRecordFfi) async {
        let previousName = group.name
        let wasArchived = group.archived
        let previousAdmins = Set(group.admins)
        let wasDisbanding = group.disbanding
        let wasDisbanded = group.disbanded
        let needsTimelineRefresh = Self.groupSnapshotNeedsTimelineTailRefresh(
            previousName: previousName,
            previousArchived: wasArchived,
            previousAdmins: previousAdmins,
            previousDisbanding: wasDisbanding,
            previousDisbanded: wasDisbanded,
            next: record
        )
        reconcileLeaveRequest(with: record.leaveRequestPending)
        applyGroupMlsTrackedChanges {
            group = record
        }

        if needsTimelineRefresh {
            scheduleTimelineTailRefresh()
        }

        if !previousName.isEmpty && previousName != record.name {
            appState?.present(.success(L10n.string("Group renamed"), message: ContentSanitizer.groupName(record.name)))
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
        previousDisbanding: Bool = false,
        previousDisbanded: Bool = false,
        next: AppGroupRecordFfi
    ) -> Bool {
        let nameChanged = !previousName.isEmpty && previousName != next.name
        let archiveStateChanged = next.archived != previousArchived
        let adminsChanged = Set(next.admins) != previousAdmins
        let disbandingChanged = next.disbanding != previousDisbanding
        let disbandedChanged = next.disbanded != previousDisbanded
        return nameChanged || archiveStateChanged || adminsChanged
            || disbandingChanged || disbandedChanged
    }

    func applyGroupRecord(_ record: AppGroupRecordFfi) {
        reconcileLeaveRequest(with: record.leaveRequestPending)
        applyGroupMlsTrackedChanges {
            group = record
        }
    }

    func applyGroupMutation(_ result: GroupMutationResultFfi) {
        applyGroupDetails(result.details, managementState: result.managementState)
        // Group system rows for our own commits are persisted in Marmot but
        // not yet broadcast on the timeline subscription (see whitenoise
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
        state.canLeave = !state.requiresSelfDemoteBeforeLeave && !state.leaveRequestPending
        managementState = state
    }

    @discardableResult
    func refreshGroupManagement(announceRosterChanges: Bool = false) async -> Bool {
        guard let appState, let accountRef = appState.activeAccountRef else { return false }
        do {
            let client = try appState.currentMarmotClient()
            let detailsStart = ContinuousClock.now
            let snapshot = try await client.groupConversationSnapshot(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )
            logLoadDuration("group.conversation_snapshot", since: detailsStart)
            applyGroupDetails(
                snapshot.details,
                managementState: snapshot.managementState,
                announceRosterChanges: announceRosterChanges
            )
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
        reconcileLeaveRequest(with: details.group.leaveRequestPending)
        group = details.group
        groupMemberDetails = details.members
        managementState = state
        members = nextMembers
        mentionRosterResolution = .resolved
        bumpGroupMlsRefreshGenerationIfNeeded(previousIdentity: previousIdentity)
        if adminsChanged || membersChanged {
            scheduleTimelineTailRefresh()
        }
    }

    private func applyGroupRoster(
        _ roster: GroupRosterFfi,
        announceRosterChanges: Bool = false
    ) {
        guard roster.groupIdHex == group.groupIdHex else { return }
        let projection = ConversationGroupRosterProjection(roster: roster)
        let previousAdmins = Set(group.admins)
        let previousMemberIds = members.map(\.memberIdHex)
        let previousIdentity = groupMlsRefreshIdentity
        let nextMembers = projection.memberRecords
        let nextMemberIds = nextMembers.map(\.memberIdHex)
        let nextAdmins = projection.adminIdsHex
        let membersChanged = Self.groupMembersNeedTimelineTailRefresh(
            previousMemberIds: previousMemberIds,
            nextMemberIds: nextMemberIds
        )
        let adminsChanged = Set(nextAdmins) != previousAdmins

        var nextGroup = group
        nextGroup.admins = nextAdmins
        nextGroup.selfMembership = projection.selfMembership
        nextGroup.unrecoverable = projection.isUnrecoverable
        nextGroup.disbanded = projection.isDisbanded
        group = nextGroup
        groupMemberDetails = projection.memberDetails
        members = nextMembers
        groupRosterRevision = projection.revision
        mentionRosterResolution = .resolved
        bumpGroupMlsRefreshGenerationIfNeeded(previousIdentity: previousIdentity)

        if announceRosterChanges && membersChanged {
            appState?.present(.success(L10n.string("Group membership updated")))
        }
        if adminsChanged || membersChanged {
            scheduleTimelineTailRefresh()
        }
    }

    private func reconcileLeaveRequest(with pending: Bool) {
        leaveRequestPending = pending
    }

#if DEBUG
    func appendSystemEventForTesting(_ event: SystemEvent, timestamp: UInt64) {
        appendSystemEvent(event, timestamp: timestamp)
    }

    func setManagementStateForTesting(_ state: GroupManagementStateFfi?) {
        managementState = state
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
            next[next.count - 1] = TimelineItem(
                id: next[next.count - 1].id,
                kind: item.kind,
                timestamp: item.timestamp
            )
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
            let roster = try await client.groupRoster(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )
            applyGroupRoster(roster, announceRosterChanges: true)
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

    func acceptInvite() async -> AppGroupRecordFfi? {
        guard hasPendingInvite,
              inviteActionInFlight == nil,
              let appState,
              let accountRef = appState.activeAccountRef
        else { return nil }
        inviteActionInFlight = .accepting
        defer { inviteActionInFlight = nil }
        for attempt in 0..<2 {
            do {
                let updated = try await performAcceptInvite(
                    accountRef: accountRef,
                    groupIdHex: group.groupIdHex
                )
                applyGroupRecord(updated)
                Haptics.success()
                return updated
            } catch let error as MarmotKitError where error.isAccountWorkerBusy {
                _ = await refreshInviteState()
                if !hasPendingInvite {
                    Haptics.success()
                    return group
                }
                if attempt == 0 {
                    do {
                        try await Task.sleep(nanoseconds: 300_000_000)
                    } catch {
                        return nil
                    }
                    continue
                }
                Haptics.error()
                appState.present(UserFacingError.toast(
                    title: L10n.string("Couldn't accept invitation"),
                    error: error
                ))
                return nil
            } catch let error as MarmotKitError where error.isAccountWorkerResponseTimedOut {
                _ = await refreshInviteState()
                if !hasPendingInvite {
                    Haptics.success()
                    return group
                }
                Haptics.error()
                appState.present(UserFacingError.toast(
                    title: L10n.string("Couldn't confirm invitation"),
                    error: error
                ))
                return nil
            } catch MarmotKitError.GroupInviteNotPending {
                // The invitation was removed or became terminal before this
                // action reached the serialized account worker. Refresh the
                // authoritative row instead of presenting a retryable failure.
                _ = await refreshInviteState()
                if !hasPendingInvite {
                    return group
                }
                Haptics.error()
                appState.present(.warning(L10n.string("This invitation is no longer available.")))
                return nil
            } catch {
                Haptics.error()
                appState.present(UserFacingError.toast(title: L10n.string("Couldn't accept invitation"), error: error))
                return nil
            }
        }
        return nil
    }

    private func performAcceptInvite(
        accountRef: String,
        groupIdHex: String
    ) async throws -> AppGroupRecordFfi {
#if DEBUG
        if let acceptGroupInviteForTesting {
            return try await acceptGroupInviteForTesting(accountRef, groupIdHex)
        }
#endif
        guard let appState else { throw CancellationError() }
        let client = try appState.currentMarmotClient()
        return try await client.acceptGroupInvite(
            accountRef: accountRef,
            groupIdHex: groupIdHex
        )
    }

    private func refreshInviteState() async -> Bool {
#if DEBUG
        if let refreshInviteStateForTesting {
            return await refreshInviteStateForTesting()
        }
#endif
        return await refreshGroupManagement()
    }

    func declineInvite() async -> AppGroupRecordFfi? {
        guard hasPendingInvite,
              inviteActionInFlight == nil,
              let appState,
              let accountRef = appState.activeAccountRef
        else { return nil }
        inviteActionInFlight = .declining
        defer { inviteActionInFlight = nil }
        do {
            let result: GroupInviteDeclineResultFfi
#if DEBUG
            if let declineGroupInviteForTesting {
                result = try await declineGroupInviteForTesting(accountRef, group.groupIdHex)
            } else {
                let client = try appState.currentMarmotClient()
                result = try await client.declineGroupInvite(
                    accountRef: accountRef,
                    groupIdHex: group.groupIdHex
                )
            }
#else
            let client = try appState.currentMarmotClient()
            result = try await client.declineGroupInvite(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )
#endif
            applyGroupRecord(result.group)
            Haptics.warning()
            return result.group
        } catch {
            Haptics.error()
            appState.present(UserFacingError.toast(title: L10n.string("Couldn't decline invitation"), error: error))
            return nil
        }
    }

    func sendPreparedComposerText(_ text: String) async {
        await composer.send(text)
    }

    func sendPreparedMedia(_ attachments: [MediaDraftAttachment], caption: String) async {
        await composer.sendMedia(attachments, caption: caption)
    }

    func forwardDestinations() async throws -> [MessageForwardDestination] {
        guard let appState, let accountRef = appState.activeAccountRef else { return [] }
        let client = try appState.currentMarmotClient()
        let rows = try await client.chatList(accountRef: accountRef, includeArchived: true)
        return MessageForwardDestinationPresentation.destinations(
            from: rows,
            excludingGroupIdHex: group.groupIdHex
        )
    }

    /// Sends exact plaintext to each selected group as a fresh, unattributed
    /// message. Fan-out is sequential so one failed destination does not race
    /// or cancel successful sends to the others.
    func forwardMessage(
        _ message: AppMessageRecordFfi,
        to groupIds: Set<String>
    ) async -> MessageForwardResult {
        await forwardMessages([message], to: groupIds)
    }

    /// Forwards selected text messages in timeline order. Messages and
    /// destinations are processed sequentially so their ordering stays stable
    /// and one destination's failure cannot cancel successful destinations.
    func forwardMessages(
        _ messages: [AppMessageRecordFfi],
        to groupIds: Set<String>
    ) async -> MessageForwardResult {
        let destinations = groupIds.filter { !$0.isEmpty && $0 != group.groupIdHex }
        let texts = messages.prefix(MessageSelectionPolicy.maximumForwardCount).compactMap {
            MessageForwardingPolicy.forwardableText(for: $0)
        }
        guard texts.count == messages.count,
              !texts.isEmpty,
              !destinations.isEmpty,
              let appState,
              let accountRef = appState.activeAccountRef,
              let client = try? appState.currentMarmotClient()
        else {
            return MessageForwardResult(successfulGroupIds: [], failedGroupIds: Set(destinations))
        }

        var successful = Set<String>()
        var failed = Set<String>()
        for destination in destinations {
            do {
                for text in texts {
                    _ = try await client.sendText(
                        accountRef: accountRef,
                        groupIdHex: destination,
                        text: text
                    )
                }
                successful.insert(destination)
            } catch {
                failed.insert(destination)
            }
        }
        if failed.isEmpty {
            Haptics.tap()
        } else {
            Haptics.error()
        }
        return MessageForwardResult(successfulGroupIds: successful, failedGroupIds: failed)
    }

    /// Re-encrypts the selected plaintext media independently for every
    /// destination. Ciphertext references are group-bound and must never be
    /// copied directly between conversations.
    func forwardMedia(
        _ media: MessageMediaAttachment,
        data: Data,
        to groupIds: Set<String>
    ) async -> MessageForwardResult {
        let destinations = groupIds.filter { !$0.isEmpty && $0 != group.groupIdHex }
        guard !destinations.isEmpty,
              let appState,
              let accountRef = appState.activeAccountRef,
              let client = try? appState.currentMarmotClient()
        else {
            return MessageForwardResult(successfulGroupIds: [], failedGroupIds: Set(destinations))
        }

        let prepared: MediaDraftAttachment
        do {
            prepared = try await MediaDraftProcessor.preparedAttachment(
                from: data,
                fileName: media.fileName,
                typeIdentifier: nil
            )
        } catch {
            return MessageForwardResult(successfulGroupIds: [], failedGroupIds: Set(destinations))
        }

        var successful = Set<String>()
        var failed = Set<String>()
        for destination in destinations {
            do {
                _ = try await client.uploadMedia(
                    accountRef: accountRef,
                    groupIdHex: destination,
                    request: MediaUploadRequestFfi(
                        attachments: [prepared.uploadRequest],
                        caption: nil,
                        send: true,
                        blossomServer: nil
                    )
                )
                successful.insert(destination)
            } catch {
                failed.insert(destination)
            }
        }
        if failed.isEmpty {
            Haptics.tap()
        } else {
            Haptics.error()
        }
        return MessageForwardResult(successfulGroupIds: successful, failedGroupIds: failed)
    }

    func editMessage(_ message: AppMessageRecordFfi, content: String) async -> Bool {
        guard MessageEditingPolicy.canEdit(
                message,
                isDeleted: isDeleted(message.messageIdHex),
                canSendMessages: canSendMessages
              ),
              let outgoing = preparedComposerText(content),
              let appState,
              let accountRef = appState.activeAccountRef
        else { return false }

        guard outgoing != message.plaintext else { return true }

        let contentTokens = await appState.parseMarkdown(text: outgoing)
        timelineStore.applyOptimisticEdit(
            to: message,
            plaintext: outgoing,
            contentTokens: contentTokens
        )
        do {
            let client = try appState.currentMarmotClient()
            _ = try await client.editMessage(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex,
                targetMessageId: message.messageIdHex,
                content: outgoing
            )
            Haptics.tap()
            return true
        } catch {
            timelineStore.rollbackOptimisticEdit(messageIdHex: message.messageIdHex)
            Haptics.error()
            appState.present(UserFacingError.toast(title: L10n.string("Send failed"), error: error))
            return false
        }
    }

#if DEBUG
    func markFailedForTesting(tempId: String) {
        markFailed(tempId: tempId)
    }
#endif

    // MARK: - Reactions

    /// Hides a message only in this account's local timeline. This path never
    /// invokes Marmot and therefore cannot publish a delete event.
    @discardableResult
    func deleteMessageForMe(_ message: AppMessageRecordFfi) async -> Bool {
        guard let canonical = canonicalDeleteRecord(for: message),
              deleteCapability(for: canonical).canDeleteForMe,
              let accountRef = appState?.activeAccountRef
        else { return false }

        let hidden = MessageHideStore.hideMessage(
            accountRef: accountRef,
            groupIdHex: group.groupIdHex,
            messageIdHex: canonical.messageIdHex
        )
        guard !hidden.isEmpty else { return false }
        timelineStore.setHiddenMessageIds(hidden)
        guard timelineStore.isHidden(canonical.messageIdHex) else { return false }
        await purgeCachedMedia(for: canonical)
        Haptics.warning()
        return true
    }

    /// Deleting a message also removes its decrypted plaintext from the
    /// media caches — hiding or tombstoning the record while its attachments
    /// stay readable on disk would contradict what "delete" promises.
    private func purgeCachedMedia(for record: AppMessageRecordFfi) async {
        let references = mediaItems(for: record).compactMap(\.reference)
        guard !references.isEmpty else { return }
        let hashes = Set(references.map { $0.ciphertextSha256.lowercased() })
        await MessageMediaCache.removeCachedData(forCiphertextHashes: hashes, in: references)
    }

    /// Tombstones a message for every participant. Authorization is rechecked
    /// here so stale UI state cannot request a broader delete scope.
    @discardableResult
    func deleteMessageForEveryone(_ message: AppMessageRecordFfi) async -> Bool {
        guard let canonical = canonicalDeleteRecord(for: message),
              deleteCapability(for: canonical).canDeleteForEveryone,
              let appState, let accountRef = appState.activeAccountRef
        else { return false }
        timelineStore.deletedProjections.insertOptimistic(canonical.messageIdHex)
        if timelineStore.deletedProjections.rebuild() {
            timelineStore.noteProjectionChanged()
        }
        do {
            let client = try appState.currentMarmotClient()
            _ = try await deleteMessageOperation(
                client,
                accountRef,
                group.groupIdHex,
                canonical.messageIdHex
            )
            await purgeCachedMedia(for: canonical)
            Haptics.warning()
            return true
        } catch {
            timelineStore.deletedProjections.removeOptimistic(canonical.messageIdHex)
            if timelineStore.deletedProjections.rebuild() {
                timelineStore.noteProjectionChanged()
            }
            Haptics.error()
            appState.present(UserFacingError.toast(title: L10n.string("Couldn't delete message"), error: error))
            return false
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
        ComposerMentionCanonicalizer.canonicalize(
            text,
            candidates: [],
            maxLength: ContentSanitizer.maxMessageLength
        )
    }

    func toggleReaction(_ emoji: String, on message: AppMessageRecordFfi) async {
        guard canSendMessages,
              let appState, let accountRef = appState.activeAccountRef,
              !message.messageIdHex.isEmpty else { return }
        let me = appState.activeAccount?.accountIdHex ?? ""
        let alreadyMine = reactions(for: message.messageIdHex).contains { $0.emoji == emoji && $0.mine }

        // Optimistic state we can roll back on failure.
        var addedKey: String?
        var removedRecords: [String: AppMessageRecordFfi] = [:]
        var removals: Set<ReactionRemoval> = []
        var clearedRemoval: ReactionRemoval?

        if alreadyMine {
            removals = Self.reactionRemovalsForUnreact(
                target: message.messageIdHex,
                tallies: reactions(for: message.messageIdHex),
                sender: me
            )
            for removal in removals {
                timelineStore.reactionProjections.insertRemoval(removal)
            }
            // Un-react removes every active reaction from this account on the
            // target, including optimistic records for other emoji.
            removedRecords = timelineStore.reactionProjections.removeMatchingRecords(
                target: message.messageIdHex,
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
        if timelineStore.recomputeReactions(for: [message.messageIdHex]) {
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
            for removal in removals {
                timelineStore.reactionProjections.removeRemoval(removal)
            }
            if let clearedRemoval { timelineStore.reactionProjections.insertRemoval(clearedRemoval) }
            timelineStore.reactionProjections.restoreRecords(removedRecords)
            if timelineStore.recomputeReactions(for: [message.messageIdHex]) {
                timelineStore.noteProjectionChanged()
            }
            Haptics.error()
            appState.present(UserFacingError.toast(title: L10n.string("Reaction failed"), error: error))
        }
    }
}

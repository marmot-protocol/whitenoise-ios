import Foundation
import Observation
import OSLog
import MarmotKit

nonisolated struct ConversationReplyPreview: Equatable {
    let name: String
    let text: String
    let media: MessageMediaAttachment?
}

/// Owns the conversation's merged timeline: the durable message mirror, the
/// optimistic overlays (pending sends, session system events, stream/debug
/// rows), the row-display projection caches (markdown / media / reaction /
/// deleted / edit), pagination edges, and the rebuild engine that folds them into the
/// published `timeline`.
///
/// Carved out of `ConversationViewModel` (Phase 5b core). The view model keeps
/// the group roster, the IO subscription tasks, the send/react/delete FFI
/// orchestration, read-marking, mention autocomplete, and lifecycle — and drives
/// this store: it feeds pages in (`applyTimelinePage`/`applyTimelineSubscriptionUpdate`),
/// hands optimistic rows to it (`applyPendingOutgoingMessage`/`confirmSent`), and
/// reads projections back out (`reactions`/`mediaItems`/`record`/…). Pure
/// timeline statics stay on `ConversationViewModel` (referenced here as
/// `ConversationViewModel.x`) so their tests are untouched.
///
/// `StreamWatcher` writes its synthetic rows into this store through
/// `StreamWatcherTimelineSink`; the apply ingest calls back into the watcher for
/// finalized-stream resolution + live-preview teardown. The view model wires
/// both refs at init.
///
/// Thin-shell ownership boundary:
/// - Binding projection mirrors: `messageById`, `messageStatusById`,
///   `replyTargetByMessageId`, `replyProjectionKnownMessageIds`,
///   `replyPreviewsByMessageId`, row media/reaction/delete inputs, pagination
///   edges. These are copied from timeline rows and never repaired from another
///   Marmot read.
/// - UI optimistic overlays: pending/failed sends, pending media, optimistic
///   reaction toggles, optimistic delete tombstones, session system rows, and
///   stream/debug preview rows.
/// - Compatibility fallbacks: tag parsing is allowed only for local/transient
///   records that have no row projection yet; row-projected `nil` / empty values
///   are authoritative. Reply text may fall back to an already-loaded target row
///   when Rust provided the target id but not a preview.
/// - UI derivations kept here: loaded-window ordering, markdown display blocks
///   from Rust `contentTokens`, and lightweight display attachment models.
@Observable
@MainActor
final class TimelineStore {
    struct DurableRowRetryState {
        let status: MessageStatus
        fileprivate let projectionRevision: UInt64
    }

    private static let performanceSignposter = OSSignposter(
        subsystem: "dev.ipf.whitenoise.ios",
        category: "Performance"
    )

    private(set) var timeline: [TimelineItem] = []
    /// Coarse invalidation token for projection data read through methods.
    private(set) var timelineProjectionGeneration = 0
    private(set) var hasMoreBefore = false
    private(set) var hasMoreAfter = false
    private(set) var isLoading = false

    /// Renderable timeline messages we've loaded by id.
    @ObservationIgnored private var messageById: [String: AppMessageRecordFfi] = [:]
    @ObservationIgnored private var messageByRowFrameKey: [String: AppMessageRecordFfi] = [:]
    @ObservationIgnored private var messageStatusById: [String: MessageStatus] = [:]
    @ObservationIgnored private var durableRowProjectionRevisionById: [String: UInt64] = [:]
    @ObservationIgnored private var nextDurableRowProjectionRevision: UInt64 = 0
    /// Own durable rows whose `sourceMessageIdHex` is still nil — committed
    /// to the group locally and still awaiting a definitive delivery outcome.
    @ObservationIgnored private var undeliveredOwnMessageIds: Set<String> = []
    /// Successful send results whose delivered timeline upsert has not been
    /// consumed yet. Marmot publishes a nil-source local projection before
    /// transport and the sourced projection after transport; the subscription
    /// can deliver that first upsert after the async send call has returned.
    @ObservationIgnored private var publishedOutgoingMessageIdsAwaitingProjection: Set<String> = []
    /// Message ids for which Rust's `replyToMessageIdHex` projection has been
    /// mirrored. Presence with no entry in `replyTargetByMessageId` means the row
    /// authoritatively has no reply target, so do not recover one from tags.
    @ObservationIgnored private var replyProjectionKnownMessageIds: Set<String> = []
    /// Real message ids returned by a successful send before Marmot has mirrored
    /// the durable timeline row. These remain local echoes and must not be evicted
    /// by a racing subscription window snapshot that was captured before the row
    /// appeared in the projected window.
    ///
    /// Invariant: an id enters here only when `confirmSent` maps a temp row to
    /// the same real id Marmot will later use in `TimelineMessageRecordFfi`.
    /// It leaves only when `applyTimelineRecord` mirrors that durable row or
    /// `removeTimelineRecord` drops the row; otherwise a stale entry would keep
    /// eviction immunity after the backend made an authoritative decision.
    @ObservationIgnored private var confirmedPendingTimelineRecordIds: Set<String> = []
    @ObservationIgnored private var replyTargetByMessageId: [String: String] = [:]
    @ObservationIgnored private var replyPreviewsByMessageId: [String: TimelineReplyPreviewFfi] = [:]
    @ObservationIgnored private var replyPreviewDisplayCache: [String: ReplyPreviewDisplayCacheEntry] = [:]
    @ObservationIgnored private var groupSystemByMessageId: [String: GroupSystemEventFfi] = [:]
    @ObservationIgnored private var groupSystemDisplayCache: [String: GroupSystemDisplayCacheEntry] = [:]
    @ObservationIgnored private var transientTimelineItems: [String: TimelineItem] = [:]
    @ObservationIgnored private var systemTimelineItems: [TimelineItem] = []
    /// Transient QUIC debug rows keyed by timeline id (streaming debug only).
    /// Written by `StreamWatcher` via the sink; consumed by `rebuildTimeline`.
    /// Bounded to a recent window (`maxStreamDebugTimelineItems`) so a long-lived
    /// stream can't grow this map for the conversation's lifetime (#431).
    @ObservationIgnored private var streamDebugTimelineItems: [String: TimelineItem] = [:]
    /// Account/group-scoped message ids hidden by the local "Delete for me"
    /// action. Records stay mirrored so reply/edit/reaction projections remain
    /// internally consistent; only the rendered timeline filters them.
    @ObservationIgnored private var hiddenMessageIds: Set<String>

    /// Upper bound on retained streaming-debug rows. Higher than
    /// `maxSystemTimelineItems` because debug events are far higher volume.
    nonisolated static let maxStreamDebugTimelineItems = 256

    @ObservationIgnored let markdownProjections = ConversationMarkdownProjectionCache()
    @ObservationIgnored let agentEventProjections = ConversationAgentEventProjectionCache()
    @ObservationIgnored let mediaProjections = ConversationMediaProjectionCache()
    @ObservationIgnored let reactionProjections = ConversationReactionProjectionCache()
    @ObservationIgnored let deletedProjections = ConversationDeletedMessageProjection()
    @ObservationIgnored let editProjections = ConversationEditProjectionCache()
    @ObservationIgnored private var timelineSignature: [TimelineItemSignature] = []
    @ObservationIgnored private var messageClusterPresentations: [String: MessageClusterPresentation] = [:]

    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private let groupIdHex: String
    @ObservationIgnored weak var streamWatcher: StreamWatcher?
    @ObservationIgnored weak var readMarker: ConversationReadMarker?
    /// Resolves a mention entity to a display name (off the profile cache); set by
    /// the view model so this store holds no profile state.
    @ObservationIgnored var mentionResolver: MarkdownMentionResolver = { _ in nil }

    init(
        appState: AppState?,
        groupIdHex: String,
        hiddenMessageIds: Set<String> = []
    ) {
        self.appState = appState
        self.groupIdHex = groupIdHex
        self.hiddenMessageIds = Set(hiddenMessageIds.compactMap { Hex.normalized32Bytes($0) })
    }

    // Loading / pagination edges are set by the view model's IO methods.
    func setLoading(_ value: Bool) { isLoading = value }
    func setHasMoreBefore(_ value: Bool) { hasMoreBefore = value }
    func setHasMoreAfter(_ value: Bool) { hasMoreAfter = value }

    private var myAccountId: String? { appState?.activeAccount?.accountIdHex }
    /// Internal (not private) to satisfy `StreamWatcherTimelineSink`.
    var streamingDebugEnabled: Bool { appState?.streamingDebugEnabled == true }
    private var mentionDisplayNameResolver: MarkdownMentionResolver { mentionResolver }

    private func resolvedAccountDisplayName(_ accountIdHex: String) -> String {
        appState?.displayName(forAccountIdHex: accountIdHex) ?? IdentityFormatter.short(accountIdHex)
    }

    private var systemEventNaming: GroupSystemEventNaming {
        GroupSystemEventNaming(
            currentAccountIdHex: myAccountId,
            displayName: { self.resolvedAccountDisplayName($0) }
        )
    }

#if DEBUG
    var markdownProjectionBuildCountForTesting: Int { markdownProjections.buildCountForTesting }
    var agentEventProjectionBuildCountForTesting: Int { agentEventProjections.buildCountForTesting }
    var groupSystemProjectionBuildCountForTesting: Int { groupSystemProjectionBuildCount }
    var mediaItemProjectionBuildCountForTesting: Int { mediaProjections.buildCountForTesting }
    var mediaReferenceCountForTesting: Int { mediaProjections.referenceCountForTesting }
    var streamDebugTimelineItemCountForTesting: Int { streamDebugTimelineItems.count }
    private(set) var timelineRebuildCountForTesting = 0
    private(set) var reactionTargetCollectionCountForTesting = 0
    private var groupSystemProjectionBuildCount = 0
#endif

    private struct MessageTimelineSignature: Equatable {
        let messageIdHex: String
        let direction: String
        let sender: String
        let plaintext: String
        let kind: UInt64
        let sourceEpoch: UInt64?
        let retentionSeconds: UInt64?
        let retentionExpiresAt: UInt64?
        let recordedAt: UInt64
        let receivedAt: UInt64
        let tokenBlockCount: Int
        let tokensTruncated: Bool
        let tagCount: Int
        let agentStatus: String?
        let agentOperation: String?
        let agentOperationName: String?

        init(_ record: AppMessageRecordFfi) {
            messageIdHex = record.messageIdHex
            direction = record.direction
            sender = record.sender
            plaintext = record.plaintext
            kind = record.kind
            sourceEpoch = record.sourceEpoch
            retentionSeconds = record.retentionSeconds
            retentionExpiresAt = record.retentionExpiresAt
            recordedAt = record.recordedAt
            receivedAt = record.receivedAt
            tokenBlockCount = record.contentTokens.blocks.count
            tokensTruncated = record.contentTokens.truncated
            tagCount = record.tags.count
            switch MessageSemantics.classify(record) {
            case .agentActivity, .agentOperation:
                agentStatus = MessageSemantics.firstValue(of: "status", in: record.tags)
                agentOperation = MessageSemantics.firstValue(of: "operation", in: record.tags)
                agentOperationName = MessageSemantics.firstValue(of: "operation-name", in: record.tags)
            default:
                agentStatus = nil
                agentOperation = nil
                agentOperationName = nil
            }
        }
    }

    private enum TimelineItemSignatureKind: Equatable {
        case message(MessageTimelineSignature, MessageStatus)
        case systemEvent(SystemEvent)
        case streamDebugEvent(StreamDebugTimelineEvent)
    }

    private struct TimelineItemSignature: Equatable {
        let id: String
        let timestamp: UInt64
        let kind: TimelineItemSignatureKind

        init(_ item: TimelineItem) {
            id = item.id
            timestamp = item.timestamp
            switch item.kind {
            case .message(let record, let status):
                kind = .message(MessageTimelineSignature(record), status)
            case .systemEvent(let event):
                kind = .systemEvent(event)
            case .streamDebugEvent(let event):
                kind = .streamDebugEvent(event)
            }
        }
    }

    private enum ReplyPreviewSourceSignature: Equatable {
        case projected(
            sender: String,
            plaintext: String,
            kind: UInt64,
            tokenBlockCount: Int,
            tokensTruncated: Bool,
            mediaJson: String?,
            media: [MediaAttachmentReferenceFfi],
            deleted: Bool
        )
        case loadedTarget(record: MessageTimelineSignature, deleted: Bool)
    }

    private struct ReplyPreviewDisplayCacheKey: Equatable {
        let messageIdHex: String
        let targetId: String
        let source: ReplyPreviewSourceSignature
    }

    private struct ReplyPreviewDisplayCacheEntry {
        let key: ReplyPreviewDisplayCacheKey
        let value: ConversationReplyPreview
    }

    private struct GroupSystemDisplayCacheKey: Equatable {
        let record: MessageTimelineSignature
        let profileGeneration: Int
    }

    private struct GroupSystemDisplayCacheEntry {
        let key: GroupSystemDisplayCacheKey
        let text: String?
    }

    // MARK: - Loaded-window queries

    /// Message ids in timeline order (oldest → newest). The read-marker's
    /// retention policy trims oldest-first so the ids most likely to still be
    /// on screen survive the cap.
    var loadedMessageIdsInTimelineOrder: [String] {
        timeline.compactMap { item in
            guard case .message(let record, _) = item.kind, !record.messageIdHex.isEmpty else {
                return nil
            }
            return record.messageIdHex
        }
    }

    // MARK: - Projection accessors

    /// Reaction tallies for a target message (empty when none).
    func reactions(for messageIdHex: String) -> [ConversationViewModel.ReactionTally] {
        _ = timelineProjectionGeneration
        return reactionProjections.tallies(forMessageId: messageIdHex)
    }

    func reactionDetails(for messageIdHex: String) -> ConversationViewModel.ReactionDetails {
        _ = timelineProjectionGeneration
        return reactionProjections.details(forMessageId: messageIdHex)
    }

    func messageClusterPresentation(for item: TimelineItem) -> MessageClusterPresentation {
        _ = timelineProjectionGeneration
        return messageClusterPresentations[item.id] ?? .none
    }

    func markdownDisplayBlocks(for item: TimelineItem) -> [MarkdownDisplayBlock]? {
        _ = timelineProjectionGeneration
        return markdownProjections.blocks(for: item)
    }

    func record(for messageIdHex: String) -> AppMessageRecordFfi? {
        _ = timelineProjectionGeneration
        return messageById[messageIdHex].map(editProjections.displayRecord(for:))
    }

    func records(forRowFrameKeys rowFrameKeys: Set<String>) -> [AppMessageRecordFfi] {
        _ = timelineProjectionGeneration
        return rowFrameKeys.compactMap { messageByRowFrameKey[$0] }
    }

    /// The quoted preview for a reply bubble, including MDK's already-resolved
    /// first media reference so rendering it never needs another metadata read.
    func replyPreview(for record: AppMessageRecordFfi) -> ConversationReplyPreview? {
        _ = timelineProjectionGeneration
        guard let targetId = replyTargetId(for: record) else {
            return nil
        }
        if let preview = replyPreviewsByMessageId[record.messageIdHex] {
            let key = ReplyPreviewDisplayCacheKey(
                messageIdHex: record.messageIdHex,
                targetId: targetId,
                source: .projected(
                    sender: preview.sender,
                    plaintext: preview.plaintext,
                    kind: preview.kind,
                    tokenBlockCount: preview.contentTokens.blocks.count,
                    tokensTruncated: preview.contentTokens.truncated,
                    mediaJson: preview.mediaJson,
                    media: preview.media,
                    deleted: preview.deleted
                )
            )
            if let cached = replyPreviewDisplayCache[record.messageIdHex], cached.key == key {
                return cached.value
            }
            let name = appState?.displayName(forAccountIdHex: preview.sender) ?? L10n.string("Unknown")
            let text = ContentSanitizer.compactSingleLine(
                MessagePreview.body(
                    preview,
                    mentionDisplayName: mentionDisplayNameResolver,
                    systemEventNaming: systemEventNaming
                ),
                maxLength: 120
            ) ?? ""
            let media = preview.deleted
                ? nil
                : MessageMediaAttachment.displayItems(
                    from: preview.media,
                    ownerId: "reply:\(record.messageIdHex):\(targetId)"
                ).first
            let value = ConversationReplyPreview(name: name, text: text, media: media)
            replyPreviewDisplayCache[record.messageIdHex] = ReplyPreviewDisplayCacheEntry(key: key, value: value)
            return value
        }
        guard let storedTarget = messageById[targetId] else {
            return nil
        }
        let target = editProjections.displayRecord(for: storedTarget)
        let targetDeleted = deletedProjections.contains(targetId)
        let key = ReplyPreviewDisplayCacheKey(
            messageIdHex: record.messageIdHex,
            targetId: targetId,
            source: .loadedTarget(
                record: MessageTimelineSignature(target),
                deleted: targetDeleted
            )
        )
        if let cached = replyPreviewDisplayCache[record.messageIdHex], cached.key == key {
            return cached.value
        }
        let name = appState?.displayName(forAccountIdHex: target.sender) ?? L10n.string("Unknown")
        let text = targetDeleted
            ? L10n.string("This message was deleted")
            : ContentSanitizer.compactSingleLine(displayBody(of: target), maxLength: 120) ?? ""
        let media = targetDeleted
            ? nil
            : mediaProjections.build(
                for: target,
                ownerId: "reply:\(record.messageIdHex):\(targetId)"
            ).first
        let value = ConversationReplyPreview(name: name, text: text, media: media)
        replyPreviewDisplayCache[record.messageIdHex] = ReplyPreviewDisplayCacheEntry(key: key, value: value)
        return value
    }

    func replyTargetMessageId(for record: AppMessageRecordFfi) -> String? {
        replyTargetId(for: record)
    }

    /// The visible body for a message, projected from the decoded unsigned
    /// Nostr app event's kind/tags/content.
    func displayBody(of record: AppMessageRecordFfi) -> String {
        MessagePreview.body(
            record,
            mentionDisplayName: mentionDisplayNameResolver,
            systemEventNaming: systemEventNaming
        )
    }

    func isDeleted(_ messageIdHex: String) -> Bool {
        _ = timelineProjectionGeneration
        return deletedProjections.contains(messageIdHex)
    }

    func isHidden(_ messageIdHex: String) -> Bool {
        _ = timelineProjectionGeneration
        guard let messageId = Hex.normalized32Bytes(messageIdHex) else { return false }
        return hiddenMessageIds.contains(messageId)
    }

    @discardableResult
    func setHiddenMessageIds(_ messageIds: Set<String>) -> Bool {
        let normalized = Set(messageIds.compactMap { Hex.normalized32Bytes($0) })
        guard hiddenMessageIds != normalized else { return false }
        hiddenMessageIds = normalized
        let changed = rebuildTimeline()
        noteProjectionChanged()
        return changed
    }

    func isEdited(_ messageIdHex: String) -> Bool {
        _ = timelineProjectionGeneration
        guard let record = messageById[messageIdHex] else { return false }
        return editProjections.isEdited(record)
    }

    /// Whether the actions menu should offer "View edit history".
    func hasEditHistory(_ messageIdHex: String) -> Bool {
        _ = timelineProjectionGeneration
        guard let record = messageById[messageIdHex] else { return false }
        return EditHistoryPresentation.shouldOffer(
            editCount: editProjections.editRecords(for: record).count,
            isDeleted: deletedProjections.contains(messageIdHex)
        )
    }

    /// Edit-history rows for a message, newest-first. The stored base record
    /// keeps the original body; its durable edits supply the later versions.
    func editHistory(for messageIdHex: String) -> [EditHistoryPresentation.Row] {
        _ = timelineProjectionGeneration
        guard let record = messageById[messageIdHex] else { return [] }
        return EditHistoryPresentation.rows(
            original: record,
            edits: editProjections.editRecords(for: record),
            mentionDisplayName: mentionDisplayNameResolver
        )
    }

    func mediaItems(for item: TimelineItem) -> [MessageMediaAttachment] {
        _ = timelineProjectionGeneration
        return mediaProjections.items(for: item)
    }

    func mediaItems(for record: AppMessageRecordFfi) -> [MessageMediaAttachment] {
        _ = timelineProjectionGeneration
        return mediaProjections.build(for: record, ownerId: record.messageIdHex)
    }

    func groupSystemDisplayText(for record: AppMessageRecordFfi) -> String? {
        _ = timelineProjectionGeneration
        let key = GroupSystemDisplayCacheKey(
            record: MessageTimelineSignature(record),
            profileGeneration: appState?.profileRefreshGeneration ?? 0
        )
        if let cached = groupSystemDisplayCache[record.messageIdHex], cached.key == key {
            return cached.text
        }
#if DEBUG
        groupSystemProjectionBuildCount += 1
#endif
        let text = GroupSystemEventPresentation.displayText(
            for: record,
            groupSystem: groupSystemByMessageId[record.messageIdHex],
            currentAccountIdHex: myAccountId,
            displayName: { self.resolvedAccountDisplayName($0) }
        )
        groupSystemDisplayCache[record.messageIdHex] = GroupSystemDisplayCacheEntry(key: key, text: text)
        return text
    }

    func agentEventDisplay(for item: TimelineItem) -> AgentEventPresentation.Display? {
        _ = timelineProjectionGeneration
        return agentEventProjections.display(for: item)
    }

    // MARK: - Page application (driven by the view model's IO)

    func applyTimelinePage(_ page: TimelinePageFfi, placement: ConversationViewModel.TimelinePagePlacement) {
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
        let timing = appState?.productAnalytics.beginTiming()
        defer { appState?.productAnalytics.recordTiming(.timelineWindow, since: timing) }

        var projectionChanged = false
        var changedReactionTargets: Set<String> = []
        let shouldEvictAbsentRecords = shouldEvictAbsentTimelineRecords(from: page)
        let canUpdateTimelineIncrementally = !shouldEvictAbsentRecords
        // Appending a multi-record page one row at a time re-sorts the whole
        // window per record; consolidate into a single rebuild for a batch.
        let consolidateTimelineRebuild = canUpdateTimelineIncrementally && page.messages.count > 1
        let perRecordTimelineUpdate = canUpdateTimelineIncrementally && !consolidateTimelineRebuild
        if shouldEvictAbsentRecords {
            let incomingMessageIds = Set(page.messages.map(\.messageIdHex).filter { !$0.isEmpty })
            for messageId in Array(messageById.keys) where !incomingMessageIds.contains(messageId) {
                if confirmedPendingTimelineRecordIds.contains(messageId) {
                    continue
                }
                projectionChanged = removeTimelineRecord(
                    messageIdHex: messageId,
                    updateTimeline: false
                ) || projectionChanged
            }
        }
        streamWatcher?.recordFinalizedStreams(in: page.messages)
        for record in page.messages {
            if !shouldEvictAbsentRecords {
                collectReactionTargets(
                    affectedBy: ConversationViewModel.appMessageRecord(from: record),
                    into: &changedReactionTargets
                )
            }
            projectionChanged = applyTimelineRecord(
                record,
                updateTimeline: perRecordTimelineUpdate
            ) || projectionChanged
        }
        if shouldEvictAbsentRecords {
            streamWatcher?.pruneScannedFinalizedMessageIds(keeping: Set(messageById.keys))
        }
        readMarker?.pruneMarkedReadMessageIds(force: true)
        hasMoreBefore = page.hasMoreBefore
        hasMoreAfter = page.hasMoreAfter
        rebuildProjectedState(
            rebuildTimeline: !canUpdateTimelineIncrementally || consolidateTimelineRebuild,
            projectionChanged: projectionChanged,
            changedReactionTargets: shouldEvictAbsentRecords ? nil : changedReactionTargets
        )
        isLoading = false
    }

    private func applyTimelineProjectionUpdate(_ runtimeUpdate: RuntimeProjectionUpdateFfi) {
        let update = runtimeUpdate.update
        guard update.groupIdHex == groupIdHex else { return }

        let timing = appState?.productAnalytics.beginTiming()
        defer { appState?.productAnalytics.recordTiming(.timelineDelta, since: timing) }

        var projectionChanged = false
        var changedReactionTargets: Set<String> = []
        // `changes` is authoritative for live deltas; the snapshot is still a bounded window.
        // A multi-change batch (e.g. relay catch-up) re-sorts the whole loaded
        // window once per record on the per-record path; instead defer to one
        // consolidated rebuild, which yields the same order in O((n+m) log n).
        let consolidateTimelineRebuild = update.changes.count > 1
        for change in update.changes {
            switch change {
            case .upsert(let trigger, let record):
                let appRecord = ConversationViewModel.appMessageRecord(from: record)
                if !appRecord.messageIdHex.isEmpty {
                    changedReactionTargets.insert(appRecord.messageIdHex)
                }
                if case .reaction(let target) = MessageSemantics.classify(appRecord), !target.isEmpty {
                    changedReactionTargets.insert(target)
                }
                streamWatcher?.recordFinalizedStreams(in: [record])
                projectionChanged = applyTimelineRecord(
                    record,
                    updateTimeline: !consolidateTimelineRebuild,
                    trigger: trigger
                ) || projectionChanged
            case .remove(let messageIdHex, _):
                if !messageIdHex.isEmpty {
                    changedReactionTargets.insert(messageIdHex)
                }
                if let existing = messageById[messageIdHex],
                   case .reaction(let target) = MessageSemantics.classify(existing),
                   !target.isEmpty {
                    changedReactionTargets.insert(target)
                }
                projectionChanged = removeTimelineRecord(
                    messageIdHex: messageIdHex,
                    updateTimeline: !consolidateTimelineRebuild
                ) || projectionChanged
            }
        }
        readMarker?.pruneMarkedReadMessageIds(force: true)
        streamWatcher?.pruneScannedFinalizedMessageIds(keeping: Set(messageById.keys))
        rebuildProjectedState(
            rebuildTimeline: consolidateTimelineRebuild,
            projectionChanged: projectionChanged,
            changedReactionTargets: changedReactionTargets
        )
        isLoading = false
    }

    private func shouldEvictAbsentTimelineRecords(from page: TimelinePageFfi) -> Bool {
        (!page.hasMoreBefore && !page.hasMoreAfter)
            || hasMoreBefore != page.hasMoreBefore
            || hasMoreAfter != page.hasMoreAfter
    }

    private func applyTimelineTailRefreshPage(_ page: TimelinePageFfi) {
        let timing = appState?.productAnalytics.beginTiming()
        defer { appState?.productAnalytics.recordTiming(.timelineTail, since: timing) }

        let existingMessageIds = Set(messageById.keys)
        let records = hasMoreAfter
            ? page.messages.filter { existingMessageIds.contains($0.messageIdHex) }
            : page.messages
        streamWatcher?.recordFinalizedStreams(in: records)
        var projectionChanged = false
        var changedReactionTargets: Set<String> = []
        for record in records {
            collectReactionTargets(affectedBy: ConversationViewModel.appMessageRecord(from: record), into: &changedReactionTargets)
            projectionChanged = applyTimelineRecord(record, updateTimeline: true) || projectionChanged
        }
        streamWatcher?.pruneScannedFinalizedMessageIds(keeping: Set(messageById.keys))
        readMarker?.pruneMarkedReadMessageIds(force: true)
        if !hasMoreAfter {
            // A tail refresh only re-reads the newest rows, so its page always
            // reports more history exists; never widen a backward edge the user
            // already exhausted, or it re-arms a redundant "load older" fetch.
            hasMoreBefore = hasMoreBefore && page.hasMoreBefore
            hasMoreAfter = page.hasMoreAfter
        }
        rebuildProjectedState(
            rebuildTimeline: false,
            projectionChanged: projectionChanged,
            changedReactionTargets: changedReactionTargets
        )
    }

    // MARK: - Record ingest

    @discardableResult
    func applyTimelineRecord(
        _ record: TimelineMessageRecordFfi,
        updateTimeline: Bool = false,
        trigger: TimelineUpdateTriggerFfi? = nil
    ) -> Bool {
        var projectionChanged = false
        let appRecord = ConversationViewModel.appMessageRecord(from: record)
        guard !appRecord.messageIdHex.isEmpty else { return false }
        if appRecord.direction == "sent" {
            nextDurableRowProjectionRevision &+= 1
            durableRowProjectionRevisionById[appRecord.messageIdHex] = nextDurableRowProjectionRevision
        }
        let semantics = MessageSemantics.classify(appRecord)
        let affectedEditTargets = editProjections.setRecord(
            appRecord,
            invalidated: record.invalidationStatus != nil,
            deleted: record.deleted
        )

        projectionChanged = true
        replyPreviewDisplayCache[appRecord.messageIdHex] = nil
        groupSystemDisplayCache[appRecord.messageIdHex] = nil
        groupSystemByMessageId[appRecord.messageIdHex] = record.groupSystem
        messageById[appRecord.messageIdHex] = appRecord
        // `sourceMessageIdHex` is the durable delivery marker. A nil-source
        // projection means committed but unresolved, except while a successful
        // send result is waiting for its sourced upsert to catch up.
        if appRecord.direction == "sent", record.sourceMessageIdHex == nil {
            if publishedOutgoingMessageIdsAwaitingProjection.contains(appRecord.messageIdHex) {
                undeliveredOwnMessageIds.remove(appRecord.messageIdHex)
            } else {
                undeliveredOwnMessageIds.insert(appRecord.messageIdHex)
            }
        } else {
            undeliveredOwnMessageIds.remove(appRecord.messageIdHex)
            publishedOutgoingMessageIdsAwaitingProjection.remove(appRecord.messageIdHex)
        }
        let replacedConfirmedPendingRow = confirmedPendingTimelineRecordIds.remove(appRecord.messageIdHex) != nil
        replyProjectionKnownMessageIds.insert(appRecord.messageIdHex)
        if let projectedReplyTarget = record.replyToMessageIdHex, !projectedReplyTarget.isEmpty {
            replyTargetByMessageId[appRecord.messageIdHex] = projectedReplyTarget
        } else {
            // Keep the "known nil" mirror explicit by clearing any previous target
            // for this row; guarded readers then suppress legacy tag fallback.
            replyTargetByMessageId[appRecord.messageIdHex] = nil
        }
        replyPreviewsByMessageId[appRecord.messageIdHex] = record.replyPreview
        // Media now arrives resolved on the row (Marmot resolves imeta + epoch);
        // mirror it instead of re-classifying tags or a separate listMedia pass.
        mediaProjections.setReferences(record.media, forMessageId: appRecord.messageIdHex)
        if replacedConfirmedPendingRow {
            // `confirmSent` keeps the freshly-picked bytes attached to the real
            // row until Marmot mirrors its authoritative record. At that point
            // the bounded decrypted-media cache owns the bytes and the pending
            // projection must be released so it cannot mask canonical metadata
            // for the lifetime of the conversation.
            mediaProjections.removePending(forRowId: "msg:\(appRecord.messageIdHex)")
        }
        reactionProjections.setSummary(record.reactions, forMessageId: appRecord.messageIdHex)
        reactionProjections.pruneConfirmedOptimistic(
            target: appRecord.messageIdHex,
            summary: record.reactions,
            me: myAccountId ?? ""
        )
        deletedProjections.setProjected(deleted: record.deleted, forMessageId: record.messageIdHex)
        let reconciledStatus = reconcilePendingOutgoingMessage(
            with: appRecord,
            replyTargetId: record.replyToMessageIdHex
        )
        projectionChanged = (reconciledStatus != nil) || projectionChanged
        messageStatusById[appRecord.messageIdHex] = durableRowStatus(
            for: appRecord,
            invalidated: record.invalidationStatus != nil
        )

        if let streamId = StreamWatcher.finalizedStreamId(from: record, appRecord: appRecord) {
            projectionChanged = (streamWatcher?.resolveFinalizedStream(streamId: streamId) ?? false) || projectionChanged
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
            for targetMessageIdHex in affectedEditTargets where targetMessageIdHex != appRecord.messageIdHex {
                if let targetItem = visibleTimelineItem(forMessageId: targetMessageIdHex) {
                    projectionChanged = upsertTimelineItem(targetItem) || projectionChanged
                }
            }
        }
        streamWatcher?.dropMatchingStreamPreviewIfNeeded(for: appRecord, semantics: semantics, trigger: trigger)
        streamWatcher?.watchStartIfNeeded(appRecord, trigger: trigger)
        return projectionChanged
    }

    @discardableResult
    func removeTimelineRecord(messageIdHex: String, updateTimeline: Bool = true) -> Bool {
        let existed = messageById[messageIdHex] != nil
        let affectedEditTargets = editProjections.removeRecord(messageIdHex: messageIdHex)
        messageById[messageIdHex] = nil
        messageStatusById[messageIdHex] = nil
        durableRowProjectionRevisionById[messageIdHex] = nil
        undeliveredOwnMessageIds.remove(messageIdHex)
        publishedOutgoingMessageIdsAwaitingProjection.remove(messageIdHex)
        confirmedPendingTimelineRecordIds.remove(messageIdHex)
        replyProjectionKnownMessageIds.remove(messageIdHex)
        replyTargetByMessageId[messageIdHex] = nil
        replyPreviewsByMessageId[messageIdHex] = nil
        replyPreviewDisplayCache[messageIdHex] = nil
        groupSystemDisplayCache[messageIdHex] = nil
        groupSystemByMessageId[messageIdHex] = nil
        mediaProjections.removeReferences(forMessageId: messageIdHex)
        reactionProjections.removeSummary(forMessageId: messageIdHex)
        deletedProjections.removeProjected(forMessageId: messageIdHex)
        readMarker?.forgetMarkIfNotPending(messageIdHex)
        streamWatcher?.forgetScannedFinalized(messageIdHex)
        var timelineChanged = updateTimeline
            ? removeTimelineItem(id: "msg:\(messageIdHex)")
            : false
        if updateTimeline {
            for targetMessageIdHex in affectedEditTargets where targetMessageIdHex != messageIdHex {
                if let targetItem = visibleTimelineItem(forMessageId: targetMessageIdHex) {
                    timelineChanged = upsertTimelineItem(targetItem) || timelineChanged
                }
            }
        }
        return existed || timelineChanged
    }

    // MARK: - Rebuild engine

    func rebuildProjectedState(
        rebuildTimeline shouldRebuildTimeline: Bool = true,
        projectionChanged: Bool = false,
        changedReactionTargets: Set<String>? = nil
    ) {
        var changed = projectionChanged
        let deletedChanged = deletedProjections.rebuild()
        changed = deletedChanged || changed
        // A delete-state change can flip tombstoned un-reacts on any target, so it
        // forces a full recompute; otherwise a live delta touches only its targets.
        if let changedReactionTargets, !deletedChanged {
            changed = recomputeReactions(for: changedReactionTargets) || changed
        } else {
            changed = recomputeReactions() || changed
        }
        if shouldRebuildTimeline {
            changed = rebuildTimeline() || changed
        }
        if changed {
            noteProjectionChanged()
        }
    }

    @discardableResult
    private func rebuildTimeline() -> Bool {
        let timing = appState?.productAnalytics.beginTiming()
        defer { appState?.productAnalytics.recordTiming(.timelineRebuild, since: timing) }

        let signpost = Self.performanceSignposter.beginInterval("TimelineStore.rebuildTimeline")
        defer { Self.performanceSignposter.endInterval("TimelineStore.rebuildTimeline", signpost) }
        #if DEBUG
        timelineRebuildCountForTesting += 1
        #endif

        var next: [TimelineItem] = messageById.values.compactMap { record in
            visibleTimelineItem(for: record, status: messageStatusById[record.messageIdHex])
        }
        next.append(contentsOf: transientTimelineItems.values)
        next.append(contentsOf: streamDebugTimelineItems.values)
        next.append(contentsOf: systemTimelineItems)
        next = ConversationViewModel.normalizedTimeline(
            from: next,
            replyTargetId: { replyTargetId(for: $0) }
        )
        let markdownTiming = appState?.productAnalytics.beginTiming()
        let markdownChanged = markdownProjections.rebuild(
            for: next,
            onlyRowsWithMentions: false,
            resolver: mentionDisplayNameResolver
        )
        appState?.productAnalytics.recordTiming(.markdownRebuild, since: markdownTiming)
        let mediaTiming = appState?.productAnalytics.beginTiming()
        let mediaChanged = mediaProjections.rebuild(for: next)
        appState?.productAnalytics.recordTiming(.mediaRebuild, since: mediaTiming)
        agentEventProjections.prune(keeping: Set(next.map(\.id)))
        return assignTimeline(next) || markdownChanged || mediaChanged
    }

    func refreshStreamingDebugPresentation() {
        var changed = false
        if !streamingDebugEnabled {
            changed = !streamDebugTimelineItems.isEmpty
            streamDebugTimelineItems.removeAll()
            streamWatcher?.resetDebugSequence()
        }
        changed = rebuildTimeline() || changed
        if changed {
            noteProjectionChanged()
        }
    }

    /// Insert `item` into `items` and evict the oldest rows so at most `limit`
    /// remain, returning the ids removed. Ordering mirrors the timeline sort
    /// (`timestamp` then `id`), so eviction matches display order and the
    /// monotonic per-event sequence baked into debug ids keeps same-second
    /// events in insertion order. Pure and total for unit coverage (#431).
    nonisolated static func retainStreamDebugTimelineItems(
        _ items: inout [String: TimelineItem],
        appending item: TimelineItem,
        limit: Int = maxStreamDebugTimelineItems
    ) -> [String] {
        items[item.id] = item
        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else {
            let evicted = Array(items.keys)
            items.removeAll()
            return evicted
        }
        guard items.count > boundedLimit else { return [] }
        let ordered = items.values.sorted { lhs, rhs in
            lhs.timestamp == rhs.timestamp ? lhs.id < rhs.id : lhs.timestamp < rhs.timestamp
        }
        let evicted = ordered.prefix(items.count - boundedLimit).map(\.id)
        for evictedId in evicted {
            items.removeValue(forKey: evictedId)
        }
        return evicted
    }

    func refreshProfileDependentTimelineProjections() {
        let timing = appState?.productAnalytics.beginTiming()
        defer { appState?.productAnalytics.recordTiming(.timelineProfiles, since: timing) }

        replyPreviewDisplayCache.removeAll()
        groupSystemDisplayCache.removeAll()
        markdownProjections.rebuild(for: timeline, onlyRowsWithMentions: true, resolver: mentionDisplayNameResolver)
        noteProjectionChanged()
    }

    private func visibleTimelineItem(
        for record: AppMessageRecordFfi,
        status: MessageStatus?
    ) -> TimelineItem? {
        if let messageId = Hex.normalized32Bytes(record.messageIdHex),
           hiddenMessageIds.contains(messageId) {
            return nil
        }
        switch MessageSemantics.classify(record) {
        case .chat, .reply, .media, .streamFinal:
            return TimelineItem.message(editProjections.displayRecord(for: record), status: status)
        case .agentActivity, .agentOperation:
            let item = TimelineItem.message(record, status: status)
            guard agentEventProjections.display(for: item) != nil else { return nil }
            return item
        case .groupSystem:
            guard GroupSystemEventPresentation.isDisplayable(
                record,
                groupSystem: groupSystemByMessageId[record.messageIdHex]
            ) else { return nil }
            return TimelineItem.message(record, status: status)
        case .reaction, .delete, .edit, .agentStreamStart, .unknown:
            guard streamingDebugEnabled else { return nil }
            return TimelineItem.message(record, status: status)
        }
    }

    @discardableResult
    private func upsertTimelineItem(_ item: TimelineItem) -> Bool {
        if let existingIndex = timeline.firstIndex(where: { $0.id == item.id }),
           canReplaceTimelineItemInPlace(old: timeline[existingIndex], next: item) {
            let markdownChanged = markdownProjections.update(for: item, resolver: mentionDisplayNameResolver)
            let mediaChanged = mediaProjections.update(for: item)
            return replaceTimelineItem(item, at: existingIndex) || markdownChanged || mediaChanged
        }
        var next = timeline.filter { $0.id != item.id }
        next.append(item)
        next = ConversationViewModel.normalizedTimeline(
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
        agentEventProjections.remove(rowId: id)
        return assignTimeline(next) || markdownChanged || mediaChanged
    }

    @discardableResult
    private func assignTimeline(_ next: [TimelineItem]) -> Bool {
        let signpost = Self.performanceSignposter.beginInterval("TimelineStore.assignTimeline")
        defer { Self.performanceSignposter.endInterval("TimelineStore.assignTimeline", signpost) }

        let nextSignature = next.map(TimelineItemSignature.init)
        messageByRowFrameKey = Self.messageRowsByFrameKey(next)
        guard timelineSignature != nextSignature else { return false }
        timeline = next
        timelineSignature = nextSignature
        messageClusterPresentations = MessageClusterProjection.presentations(for: next)
        return true
    }

    private func replaceTimelineItem(_ item: TimelineItem, at index: Int) -> Bool {
        let signature = TimelineItemSignature(item)
        if index < timelineSignature.count, timelineSignature[index] == signature {
            return false
        }
        timeline[index] = item
        if case .message(let record, _) = item.kind {
            messageByRowFrameKey[item.rowFrameKey] = record
        } else {
            messageByRowFrameKey[item.rowFrameKey] = nil
        }
        if timelineSignature.count == timeline.count {
            timelineSignature[index] = signature
        } else {
            timelineSignature = timeline.map(TimelineItemSignature.init)
        }
        messageClusterPresentations = MessageClusterProjection.presentations(for: timeline)
        return true
    }

    private static func messageRowsByFrameKey(
        _ timeline: [TimelineItem]
    ) -> [String: AppMessageRecordFfi] {
        var records: [String: AppMessageRecordFfi] = [:]
        records.reserveCapacity(timeline.count)
        for item in timeline {
            guard case .message(let record, _) = item.kind else { continue }
            records[item.rowFrameKey] = record
        }
        return records
    }

    private func canReplaceTimelineItemInPlace(old: TimelineItem, next: TimelineItem) -> Bool {
        guard old.id == next.id, old.timestamp == next.timestamp else { return false }
        switch (old.kind, next.kind) {
        case (.message(let oldRecord, _), .message(let nextRecord, _)):
            return replyTargetId(for: oldRecord) == replyTargetId(for: nextRecord)
        case (.systemEvent, .systemEvent), (.streamDebugEvent, .streamDebugEvent):
            return true
        default:
            return false
        }
    }

    func noteProjectionChanged() {
        timelineProjectionGeneration += 1
    }

    /// Resolves a loaded message id to its current visible timeline row, for the
    /// media cache's by-message-id projection refresh.
    private func visibleTimelineItem(forMessageId messageIdHex: String) -> TimelineItem? {
        guard let record = messageById[messageIdHex] else { return nil }
        return visibleTimelineItem(for: record, status: messageStatusById[messageIdHex])
    }

    private func replyTargetId(for record: AppMessageRecordFfi) -> String? {
        if replyProjectionKnownMessageIds.contains(record.messageIdHex) {
            return replyTargetByMessageId[record.messageIdHex]
        }
        return ConversationViewModel.replyTargetMessageId(in: record)
    }

    // MARK: - Reactions

    /// All aggregated reaction tallies (full dict) — for test hooks.
    var reactions: [String: [ConversationViewModel.ReactionTally]] { reactionProjections.allTallies }

    private func collectReactionTargets(affectedBy record: AppMessageRecordFfi, into targets: inout Set<String>) {
#if DEBUG
        reactionTargetCollectionCountForTesting += 1
#endif
        if !record.messageIdHex.isEmpty {
            targets.insert(record.messageIdHex)
        }
        if case .reaction(let target) = MessageSemantics.classify(record), !target.isEmpty {
            targets.insert(target)
        }
    }

    @discardableResult
    func recomputeReactions() -> Bool {
        reactionProjections.recompute(deletedMessageIds: deletedProjections.deletedMessageIds, me: myAccountId ?? "")
    }

    @discardableResult
    func recomputeReactions(for targets: Set<String>) -> Bool {
        reactionProjections.recompute(targets: targets, deletedMessageIds: deletedProjections.deletedMessageIds, me: myAccountId ?? "")
    }

#if DEBUG
    @discardableResult
    func forceFullReactionRecomputeForTesting() -> [String: [ConversationViewModel.ReactionTally]] {
        _ = recomputeReactions()
        return reactions
    }
#endif

    // MARK: - Optimistic send overlay

    func applyPendingOutgoingMessage(tempId: String, record: AppMessageRecordFfi) {
        let timing = appState?.productAnalytics.beginTiming()
        defer { appState?.productAnalytics.recordTiming(.outgoingProjection, since: timing) }

        let item = TimelineItem.pendingMessage(tempId: tempId, record: record)
        transientTimelineItems[item.id] = item
        let changed = upsertTimelineItem(item)
        if changed {
            noteProjectionChanged()
        }
    }

    func confirmSent(tempId: String, record: AppMessageRecordFfi, messageId: String?) {
        let timing = appState?.productAnalytics.beginTiming()
        defer { appState?.productAnalytics.recordTiming(.outgoingConfirmation, since: timing) }

        var projectionChanged = false
        let realId = messageId ?? ""
        let durableRowAlreadyLoaded = !realId.isEmpty && messageById[realId] != nil
        let confirmed = AppMessageRecordFfi(
            messageIdHex: realId,
            direction: "sent",
            groupIdHex: record.groupIdHex,
            sender: record.sender,
            plaintext: record.plaintext,
            contentTokens: record.contentTokens,
            kind: record.kind,
            tags: record.tags,
            sourceEpoch: record.sourceEpoch,
            retentionSeconds: record.retentionSeconds,
            retentionExpiresAt: record.retentionExpiresAt,
            recordedAt: record.recordedAt,
            receivedAt: record.receivedAt
        )
        if !realId.isEmpty {
            // A confirmed real-id row is still an optimistic local echo until
            // Marmot mirrors the authoritative timeline row, so leave it out of
            // replyProjectionKnownMessageIds. See
            // confirmedPendingTimelineRecordIds for the eviction-immunity
            // lifecycle; reply fallbacks stay local-only in that window.
            if !replyProjectionKnownMessageIds.contains(realId) {
                confirmedPendingTimelineRecordIds.insert(realId)
            }
            if messageById[realId] == nil {
                messageById[realId] = confirmed
                projectionChanged = true
            }
            let needsProjectionAckGuard = !durableRowAlreadyLoaded
                || undeliveredOwnMessageIds.contains(realId)
            if needsProjectionAckGuard {
                publishedOutgoingMessageIdsAwaitingProjection.insert(realId)
            }
            undeliveredOwnMessageIds.remove(realId)
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
        // Re-stage the just-picked bytes under the confirmed row id (real or
        // temp) so the sent bubble keeps rendering from memory instead of
        // re-downloading and re-decrypting the attachment we just uploaded. The
        // real-id branches previously dropped these, forcing a needless fetch.
        if let removedPendingMedia {
            mediaProjections.setPending(removedPendingMedia, forRowId: rowId)
        }
        if realId.isEmpty {
            // No server message id: the row stays transient under "msg:\(tempId)".
            let item = TimelineItem(
                id: rowId,
                kind: .message(record: confirmed, status: .sent),
                timestamp: confirmed.recordedAt
            )
            transientTimelineItems[rowId] = item
            projectionChanged = true
            projectionChanged = upsertTimelineItem(item) || projectionChanged
        } else if durableRowAlreadyLoaded {
            if let item = visibleTimelineItem(forMessageId: realId) {
                projectionChanged = upsertTimelineItem(item) || projectionChanged
            }
        } else {
            projectionChanged = upsertTimelineItem(
                TimelineItem.message(confirmed, status: messageStatusById[realId] ?? .sent)
            ) || projectionChanged
        }
        if projectionChanged {
            noteProjectionChanged()
        }
    }

    /// Delivery-aware status for a durable row. A nil source is a durable,
    /// unresolved delivery state rather than a failure; Marmot invalidation is
    /// the definitive failure signal.
    private func durableRowStatus(
        for record: AppMessageRecordFfi,
        invalidated: Bool
    ) -> MessageStatus {
        guard record.direction == "sent" else { return .received }
        guard !invalidated else { return .failed }
        guard undeliveredOwnMessageIds.contains(record.messageIdHex) else { return .sent }
        return .sending
    }

    /// The mirrored record for a durable timeline row, if loaded.
    func durableRecord(messageIdHex: String) -> AppMessageRecordFfi? {
        messageById[messageIdHex]
    }

    /// Marks a durable row delivered on the engine's publish ack when the
    /// healed row sits outside the refreshed window; the next mirrored
    /// record remains authoritative either way.
    func markDurableRowDelivered(messageIdHex: String) {
        undeliveredOwnMessageIds.remove(messageIdHex)
        setDurableRowStatus(.sent, messageIdHex: messageIdHex)
    }

    /// Captures the current presentation state before a durable retry applies
    /// its temporary sending status.
    func durableRowStatusBeforeRetry(messageIdHex: String) -> DurableRowRetryState? {
        guard undeliveredOwnMessageIds.contains(messageIdHex),
              let status = messageStatusById[messageIdHex]
        else { return nil }
        return DurableRowRetryState(
            status: status,
            projectionRevision: durableRowProjectionRevisionById[messageIdHex] ?? 0
        )
    }

    /// Rolls back only the retry's temporary status. A newer authoritative
    /// projection (including delivery) keeps precedence.
    func restoreDurableRowStatusAfterRetry(
        _ retryState: DurableRowRetryState,
        messageIdHex: String
    ) {
        guard undeliveredOwnMessageIds.contains(messageIdHex),
              durableRowProjectionRevisionById[messageIdHex] == retryState.projectionRevision,
              messageStatusById[messageIdHex] == .sending
        else { return }
        setDurableRowStatus(retryState.status, messageIdHex: messageIdHex)
    }

    /// Temporary UI status for a durable row during a user-driven retry —
    /// delivery truth still comes from the next mirrored timeline record.
    func setDurableRowStatus(_ status: MessageStatus, messageIdHex: String) {
        guard messageById[messageIdHex] != nil, messageStatusById[messageIdHex] != status else { return }
        messageStatusById[messageIdHex] = status
        if let item = visibleTimelineItem(forMessageId: messageIdHex) {
            _ = upsertTimelineItem(item)
        }
        noteProjectionChanged()
    }

    /// The message id of a durable own row that was committed but never
    /// delivered, if `rowId` names one. These retry through group
    /// convergence — re-sending the text would mint a duplicate message.
    func undeliveredDurableMessageId(rowId: String) -> String? {
        guard rowId.hasPrefix("msg:") else { return nil }
        let messageIdHex = String(rowId.dropFirst("msg:".count))
        return undeliveredOwnMessageIds.contains(messageIdHex) ? messageIdHex : nil
    }

    /// Whether a failed optimistic row still has staged local media — a media
    /// send's optimistic record carries no imeta tags, so this projection is
    /// the reliable media discriminator for retry gating.
    func failedTransientRowHasStagedMedia(rowId: String) -> Bool {
        mediaProjections.pending(forRowId: rowId)?.isEmpty == false
    }

    /// The optimistic record still held for a failed outgoing row, if that
    /// row exists and is in the `.failed` state. Retry/discard key off the
    /// row id (`msg:<tempId>`), the only stable handle for an optimistic
    /// message whose real message id is still empty.
    func failedTransientRecord(rowId: String) -> AppMessageRecordFfi? {
        guard let item = transientTimelineItems[rowId],
              case .message(let record, let status) = item.kind,
              status == .failed
        else { return nil }
        return record
    }

    /// Removes a transient (optimistic) row outright — used to discard a
    /// failed send the user no longer wants.
    func discardTransientRow(rowId: String) {
        guard transientTimelineItems[rowId] != nil else { return }
        transientTimelineItems[rowId] = nil
        mediaProjections.removePending(forRowId: rowId)
        if removeTimelineItem(id: rowId) {
            noteProjectionChanged()
        }
    }

    func markFailed(tempId: String) {
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
            noteProjectionChanged()
        }
    }

    /// Consumes the optimistic transient row the durable `record` confirms,
    /// returning the consumed row's status (nil when nothing matched) — the
    /// caller needs to know whether it swallowed an in-flight send or an
    /// already-settled failure.
    @discardableResult
    private func reconcilePendingOutgoingMessage(with record: AppMessageRecordFfi, replyTargetId: String?) -> MessageStatus? {
        guard record.direction == "sent" else { return nil }
        let projectedReplyTarget = replyTargetId ?? ConversationViewModel.replyTargetMessageId(in: record)
        let matchingPendingMessages = transientTimelineItems.filter { key, item in
            ConversationViewModel.pendingOutgoingMessage(
                item,
                matches: record,
                replyTargetId: projectedReplyTarget,
                pendingHasStagedMedia: mediaProjections.pending(forRowId: key)?.isEmpty == false
            )
        }
        guard let match = matchingPendingMessages.min(by: { lhs, rhs in
            ConversationViewModel.pendingOutgoingMessage(lhs.value, isCloserTo: record, than: rhs.value)
        }) else { return nil }
        transientTimelineItems[match.key] = nil
        mediaProjections.removePending(forRowId: match.key)
        _ = removeTimelineItem(id: match.value.id)
        guard case .message(_, let status) = match.value.kind else { return .sent }
        return status
    }

    /// Mirrors the resolved references for one message (from the timeline row, or
    /// from an upload result so a just-sent bubble renders before its row
    /// arrives) and refreshes that message's projection.
    @discardableResult
    func replaceMediaReferences(_ references: [MediaAttachmentReferenceFfi], forMessageId messageIdHex: String) -> Bool {
        mediaProjections.replaceReferences(
            references,
            forMessageId: messageIdHex,
            itemResolver: { [weak self] in self?.visibleTimelineItem(forMessageId: $0) }
        )
    }

    // MARK: - Optimistic edits

    func applyOptimisticEdit(
        to message: AppMessageRecordFfi,
        plaintext: String,
        contentTokens: MarkdownDocumentFfi
    ) {
        editProjections.setOptimistic(
            targetMessageIdHex: message.messageIdHex,
            sender: message.sender,
            plaintext: plaintext,
            contentTokens: contentTokens
        )
        if let item = visibleTimelineItem(forMessageId: message.messageIdHex) {
            _ = upsertTimelineItem(item)
        }
        noteProjectionChanged()
    }

    func rollbackOptimisticEdit(messageIdHex: String) {
        editProjections.removeOptimistic(targetMessageIdHex: messageIdHex)
        if let item = visibleTimelineItem(forMessageId: messageIdHex) {
            _ = upsertTimelineItem(item)
        }
        noteProjectionChanged()
    }

    // MARK: - Session system events

    func appendSystemEvent(_ event: SystemEvent, timestamp: UInt64) {
        let item = TimelineItem.systemEvent(id: UUID().uuidString, event: event, timestamp: timestamp)
        let previousItems = systemTimelineItems
        systemTimelineItems = ConversationViewModel.retainedSystemTimelineItems(
            systemTimelineItems,
            appending: item,
            limit: ConversationViewModel.maxSystemTimelineItems
        )

        let retainedIds = Set(systemTimelineItems.map(\.id))
        var changed = false
        for previousItem in previousItems where !retainedIds.contains(previousItem.id) {
            changed = removeTimelineItem(id: previousItem.id) || changed
        }
        // Publish the last retained row, not `item`: a same-kind append collapses
        // into the previous row (keeping its id, taking the new timestamp), so
        // `item`'s fresh id is absent and its new timestamp would never reach the
        // timeline until an unrelated full rebuild.
        if let published = systemTimelineItems.last {
            changed = upsertTimelineItem(published) || changed
        }
        if changed {
            noteProjectionChanged()
        }
    }

    // MARK: - Optimistic reset

    func resetOptimisticState() {
        let backingChanged = deletedProjections.hasOptimistic ||
            reactionProjections.hasOptimistic ||
            editProjections.hasOptimistic ||
            !systemTimelineItems.isEmpty ||
            mediaProjections.hasPending ||
            !transientTimelineItems.isEmpty ||
            !publishedOutgoingMessageIdsAwaitingProjection.isEmpty
        deletedProjections.removeAllOptimistic()
        reactionProjections.removeAllOptimistic()
        editProjections.removeAllOptimistic()
        systemTimelineItems.removeAll()
        transientTimelineItems.removeAll()
        publishedOutgoingMessageIdsAwaitingProjection.removeAll()
        mediaProjections.removeAllPending()
        let deletedChanged = deletedProjections.rebuild()
        let reactionsChanged = recomputeReactions()
        let timelineChanged = backingChanged ? rebuildTimeline() : false
        let changed = backingChanged || deletedChanged || reactionsChanged || timelineChanged
        if changed {
            noteProjectionChanged()
        }
    }
}

// MARK: - StreamWatcher timeline sink

extension TimelineStore: StreamWatcherTimelineSink {
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
        let evictedIds = TimelineStore.retainStreamDebugTimelineItems(
            &streamDebugTimelineItems,
            appending: item,
            limit: TimelineStore.maxStreamDebugTimelineItems
        )
        var changed = false
        for evictedId in evictedIds {
            changed = removeTimelineItem(id: evictedId) || changed
        }
        // The newest row was evicted by the cap itself (limit <= 0); nothing to show.
        guard streamDebugTimelineItems[item.id] != nil else { return changed }
        return upsertTimelineItem(item) || changed
    }

    func streamNoteProjectionChanged() {
        noteProjectionChanged()
    }
}

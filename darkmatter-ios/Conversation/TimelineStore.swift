import Foundation
import Observation
import MarmotKit

/// Owns the conversation's merged timeline: the durable message mirror, the
/// optimistic overlays (pending sends, session system events, stream/debug
/// rows), the four row-display projection caches (markdown / media / reaction /
/// deleted), pagination edges, and the rebuild engine that folds them into the
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
    private(set) var timeline: [TimelineItem] = []
    /// Coarse invalidation token for projection data read through methods.
    private(set) var timelineProjectionGeneration = 0
    private(set) var hasMoreBefore = false
    private(set) var hasMoreAfter = false
    private(set) var isLoading = false

    /// Renderable timeline messages we've loaded by id.
    @ObservationIgnored private var messageById: [String: AppMessageRecordFfi] = [:]
    @ObservationIgnored private var messageStatusById: [String: MessageStatus] = [:]
    /// Message ids for which Rust's `replyToMessageIdHex` projection has been
    /// mirrored. Presence with no entry in `replyTargetByMessageId` means the row
    /// authoritatively has no reply target, so do not recover one from tags.
    @ObservationIgnored private var replyProjectionKnownMessageIds: Set<String> = []
    @ObservationIgnored private var replyTargetByMessageId: [String: String] = [:]
    @ObservationIgnored private var replyPreviewsByMessageId: [String: TimelineReplyPreviewFfi] = [:]
    @ObservationIgnored private var transientTimelineItems: [String: TimelineItem] = [:]
    @ObservationIgnored private var systemTimelineItems: [TimelineItem] = []
    /// Transient QUIC debug rows keyed by timeline id (streaming debug only).
    /// Written by `StreamWatcher` via the sink; consumed by `rebuildTimeline`.
    @ObservationIgnored private var streamDebugTimelineItems: [String: TimelineItem] = [:]

    @ObservationIgnored let markdownProjections = ConversationMarkdownProjectionCache()
    @ObservationIgnored let mediaProjections = ConversationMediaProjectionCache()
    @ObservationIgnored let reactionProjections = ConversationReactionProjectionCache()
    @ObservationIgnored let deletedProjections = ConversationDeletedMessageProjection()

    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private let groupIdHex: String
    @ObservationIgnored weak var streamWatcher: StreamWatcher?
    @ObservationIgnored weak var readMarker: ConversationReadMarker?
    /// Resolves a mention entity to a display name (off the profile cache); set by
    /// the view model so this store holds no profile state.
    @ObservationIgnored var mentionResolver: MarkdownMentionResolver = { _ in nil }

    init(appState: AppState?, groupIdHex: String) {
        self.appState = appState
        self.groupIdHex = groupIdHex
    }

    // Loading / pagination edges are set by the view model's IO methods.
    func setLoading(_ value: Bool) { isLoading = value }
    func setHasMoreBefore(_ value: Bool) { hasMoreBefore = value }
    func setHasMoreAfter(_ value: Bool) { hasMoreAfter = value }

    private var myAccountId: String? { appState?.activeAccount?.accountIdHex }
    /// Internal (not private) to satisfy `StreamWatcherTimelineSink`.
    var streamingDebugEnabled: Bool { appState?.streamingDebugEnabled == true }
    private var mentionDisplayNameResolver: MarkdownMentionResolver { mentionResolver }

#if DEBUG
    var mediaItemProjectionBuildCountForTesting: Int { mediaProjections.buildCountForTesting }
    var mediaReferenceCountForTesting: Int { mediaProjections.referenceCountForTesting }
#endif

    // MARK: - Loaded-window queries

    var loadedMessageIds: Set<String> { Set(messageById.keys) }

    // MARK: - Projection accessors

    /// Reaction tallies for a target message (empty when none).
    func reactions(for messageIdHex: String) -> [ConversationViewModel.ReactionTally] {
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
        guard let targetId = replyTargetId(for: record) else {
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

    func isDeleted(_ messageIdHex: String) -> Bool {
        _ = timelineProjectionGeneration
        return deletedProjections.contains(messageIdHex)
    }

    func mediaItems(for item: TimelineItem) -> [MessageMediaAttachment] {
        _ = timelineProjectionGeneration
        return mediaProjections.items(for: item)
    }

    func mediaItems(for record: AppMessageRecordFfi) -> [MessageMediaAttachment] {
        _ = timelineProjectionGeneration
        return mediaProjections.build(for: record, ownerId: record.messageIdHex)
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
        streamWatcher?.recordFinalizedStreams(in: page.messages)
        for record in page.messages {
            projectionChanged = applyTimelineRecord(record) || projectionChanged
        }
        if shouldEvictAbsentRecords {
            streamWatcher?.pruneScannedFinalizedMessageIds(keeping: Set(messageById.keys))
        }
        readMarker?.pruneMarkedReadMessageIds(force: true)
        hasMoreBefore = page.hasMoreBefore
        hasMoreAfter = page.hasMoreAfter
        rebuildProjectedState(projectionChanged: projectionChanged)
        isLoading = false
    }

    private func applyTimelineProjectionUpdate(_ runtimeUpdate: RuntimeProjectionUpdateFfi) {
        let update = runtimeUpdate.update
        guard update.groupIdHex == groupIdHex else { return }

        var projectionChanged = false
        var changedReactionTargets: Set<String> = []
        // `changes` is authoritative for live deltas; the snapshot is still a bounded window.
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
                projectionChanged = applyTimelineRecord(record, trigger: trigger) || projectionChanged
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
                    updateTimeline: false
                ) || projectionChanged
            }
        }
        readMarker?.pruneMarkedReadMessageIds(force: true)
        rebuildProjectedState(projectionChanged: projectionChanged, changedReactionTargets: changedReactionTargets)
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
        streamWatcher?.recordFinalizedStreams(in: records)
        var projectionChanged = false
        for record in records {
            projectionChanged = applyTimelineRecord(record) || projectionChanged
        }
        streamWatcher?.pruneScannedFinalizedMessageIds(keeping: Set(messageById.keys))
        readMarker?.pruneMarkedReadMessageIds(force: true)
        if !hasMoreAfter {
            hasMoreBefore = page.hasMoreBefore
            hasMoreAfter = page.hasMoreAfter
        }
        rebuildProjectedState(projectionChanged: projectionChanged)
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
        let semantics = MessageSemantics.classify(appRecord)

        projectionChanged = true
        messageById[appRecord.messageIdHex] = appRecord
        messageStatusById[appRecord.messageIdHex] = appRecord.direction == "sent" ? .sent : .received
        replyProjectionKnownMessageIds.insert(appRecord.messageIdHex)
        if let projectedReplyTarget = record.replyToMessageIdHex, !projectedReplyTarget.isEmpty {
            replyTargetByMessageId[appRecord.messageIdHex] = projectedReplyTarget
        } else {
            replyTargetByMessageId[appRecord.messageIdHex] = nil
        }
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
        }
        streamWatcher?.dropMatchingStreamPreviewIfNeeded(for: appRecord, semantics: semantics, trigger: trigger)
        streamWatcher?.watchStartIfNeeded(appRecord, trigger: trigger)
        return projectionChanged
    }

    @discardableResult
    func removeTimelineRecord(messageIdHex: String, updateTimeline: Bool = true) -> Bool {
        let existed = messageById[messageIdHex] != nil
        messageById[messageIdHex] = nil
        messageStatusById[messageIdHex] = nil
        replyProjectionKnownMessageIds.remove(messageIdHex)
        replyTargetByMessageId[messageIdHex] = nil
        replyPreviewsByMessageId[messageIdHex] = nil
        mediaProjections.removeReferences(forMessageId: messageIdHex)
        reactionProjections.removeSummary(forMessageId: messageIdHex)
        deletedProjections.removeProjected(forMessageId: messageIdHex)
        readMarker?.forgetMarkIfNotPending(messageIdHex)
        streamWatcher?.forgetScannedFinalized(messageIdHex)
        let timelineChanged = updateTimeline
            ? removeTimelineItem(id: "msg:\(messageIdHex)")
            : false
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
            streamWatcher?.resetDebugSequence()
        }
        changed = rebuildTimeline() || changed
        if changed {
            noteProjectionChanged()
        }
    }

    func refreshProfileDependentTimelineProjections() {
        if markdownProjections.rebuild(for: timeline, onlyRowsWithMentions: true, resolver: mentionDisplayNameResolver) {
            noteProjectionChanged()
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
        return assignTimeline(next) || markdownChanged || mediaChanged
    }

    @discardableResult
    private func assignTimeline(_ next: [TimelineItem]) -> Bool {
        guard timeline != next else { return false }
        timeline = next
        return true
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
        let item = TimelineItem.pendingMessage(tempId: tempId, record: record)
        transientTimelineItems[item.id] = item
        let changed = upsertTimelineItem(item)
        if changed {
            noteProjectionChanged()
        }
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

    @discardableResult
    private func reconcilePendingOutgoingMessage(with record: AppMessageRecordFfi, replyTargetId: String?) -> Bool {
        guard record.direction == "sent" else { return false }
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
        }) else { return false }
        transientTimelineItems[match.key] = nil
        mediaProjections.removePending(forRowId: match.key)
        _ = removeTimelineItem(id: match.value.id)
        return true
    }

    /// Mirrors the resolved references for one message (from the timeline row, or
    /// from an upload result so a just-sent bubble renders before its row
    /// arrives) and refreshes that message's projection.
    @discardableResult
    func replaceMediaReferences(_ references: [MediaAttachmentReferenceFfi], forMessageId messageIdHex: String) -> Bool {
        mediaProjections.replaceReferences(
            references,
            forMessageId: messageIdHex,
            itemResolver: { [unowned self] in visibleTimelineItem(forMessageId: $0) }
        )
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
        if systemTimelineItems.contains(where: { $0.id == item.id }) {
            changed = upsertTimelineItem(item) || changed
        }
        if changed {
            noteProjectionChanged()
        }
    }

    // MARK: - Optimistic reset

    func resetOptimisticState() {
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
        streamDebugTimelineItems[item.id] = item
        return upsertTimelineItem(item)
    }

    func streamNoteProjectionChanged() {
        noteProjectionChanged()
    }
}

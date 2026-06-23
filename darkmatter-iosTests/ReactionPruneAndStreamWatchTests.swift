import Testing
import Foundation
@testable import darkmatter_ios
@testable import MarmotKit

/// #47 — optimistic reaction placeholders must be pruned once the server
/// projection confirms them, so reactionRecords doesn't grow over a session.
struct OptimisticReactionPruneTests {
    private let me = String(repeating: "1", count: 64)
    private let target = String(repeating: "a", count: 64)

    private func optimisticReaction(emoji: String, sender: String, target: String) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: "optimistic-\(emoji)-\(sender)",
            direction: "sent",
            groupIdHex: String(repeating: "c", count: 64),
            sender: sender,
            plaintext: emoji,
            kind: MessageSemantics.kindReaction,
            tags: [MessageTagFfi(values: [MessageSemantics.eventRefTag, target])],
            recordedAt: 1,
            receivedAt: 1
        )
    }

    @Test func dropsOptimisticReactionConfirmedByServerSummary() {
        let record = optimisticReaction(emoji: "👍", sender: me, target: target)
        let summary = TimelineReactionSummaryFfi(
            byEmoji: [TimelineReactionEmojiFfi(emoji: "👍", senders: [me])],
            userReactions: []
        )
        let pruned = ConversationViewModel.prunedConfirmedOptimisticReactions(
            [record.messageIdHex: record], target: target, summary: summary, me: me
        )
        #expect(pruned.isEmpty)
    }

    @Test func keepsOptimisticReactionNotYetInSummary() {
        let record = optimisticReaction(emoji: "👍", sender: me, target: target)
        let summary = TimelineReactionSummaryFfi(byEmoji: [], userReactions: [])
        let pruned = ConversationViewModel.prunedConfirmedOptimisticReactions(
            [record.messageIdHex: record], target: target, summary: summary, me: me
        )
        #expect(pruned.count == 1)
    }

    @Test func keepsReactionsForADifferentTargetOrEmoji() {
        let record = optimisticReaction(emoji: "👍", sender: me, target: target)
        let summary = TimelineReactionSummaryFfi(
            byEmoji: [TimelineReactionEmojiFfi(emoji: "👍", senders: [me])],
            userReactions: []
        )
        // Summary belongs to a different target — record must be kept.
        let otherTarget = String(repeating: "b", count: 64)
        #expect(ConversationViewModel.prunedConfirmedOptimisticReactions(
            [record.messageIdHex: record], target: otherTarget, summary: summary, me: me
        ).count == 1)
        // Summary confirms a different emoji — record must be kept.
        let heart = optimisticReaction(emoji: "❤️", sender: me, target: target)
        #expect(ConversationViewModel.prunedConfirmedOptimisticReactions(
            [heart.messageIdHex: heart], target: target, summary: summary, me: me
        ).count == 1)
    }
}

/// #349 — the remove-side analog of #47. An optimistic `ReactionRemoval`
/// suppresses `me` from a target+emoji tally until the un-react lands
/// server-side. Once the authoritative summary for that target no longer
/// lists `me` for the emoji the removal is confirmed and must be dropped,
/// otherwise it leaks for the conversation's lifetime and can silently
/// subtract a later genuine re-reaction.
struct OptimisticReactionRemovalPruneTests {
    private let me = String(repeating: "1", count: 64)
    private let other = String(repeating: "2", count: 64)
    private let target = String(repeating: "a", count: 64)

    private func removal(emoji: String, sender: String, target: String) -> ConversationViewModel.ReactionRemoval {
        ConversationViewModel.ReactionRemoval(
            targetMessageIdHex: target,
            emoji: emoji,
            sender: sender
        )
    }

    @Test func dropsRemovalWhenServerSummaryNoLongerListsMe() {
        // Un-react confirmed: the summary for this target has no entry for me.
        let summary = TimelineReactionSummaryFfi(byEmoji: [], userReactions: [])
        let pruned = ConversationViewModel.prunedConfirmedOptimisticReactionRemovals(
            [removal(emoji: "❤️", sender: me, target: target)],
            target: target, summary: summary, me: me
        )
        #expect(pruned.isEmpty)
    }

    @Test func dropsRemovalWhenOtherSendersRemainButMeDoesNot() {
        // Someone else still reacts ❤️ on this target, but me does not —
        // my un-react is still confirmed, so the removal is dropped.
        let summary = TimelineReactionSummaryFfi(
            byEmoji: [TimelineReactionEmojiFfi(emoji: "❤️", senders: [other])],
            userReactions: []
        )
        let pruned = ConversationViewModel.prunedConfirmedOptimisticReactionRemovals(
            [removal(emoji: "❤️", sender: me, target: target)],
            target: target, summary: summary, me: me
        )
        #expect(pruned.isEmpty)
    }

    @Test func keepsRemovalWhileServerSummaryStillListsMe() {
        // Un-react not yet propagated — summary still attributes ❤️ to me, so
        // keep suppressing it optimistically.
        let summary = TimelineReactionSummaryFfi(
            byEmoji: [TimelineReactionEmojiFfi(emoji: "❤️", senders: [me])],
            userReactions: []
        )
        let pruned = ConversationViewModel.prunedConfirmedOptimisticReactionRemovals(
            [removal(emoji: "❤️", sender: me, target: target)],
            target: target, summary: summary, me: me
        )
        #expect(pruned.count == 1)
    }

    @Test func leavesRemovalsForADifferentTargetUntouched() {
        // The reconciler runs per incoming-record target; a removal for another
        // target must never be dropped by this target's summary.
        let otherTarget = String(repeating: "b", count: 64)
        let summary = TimelineReactionSummaryFfi(byEmoji: [], userReactions: [])
        let pruned = ConversationViewModel.prunedConfirmedOptimisticReactionRemovals(
            [removal(emoji: "❤️", sender: me, target: otherTarget)],
            target: target, summary: summary, me: me
        )
        #expect(pruned.count == 1)
    }

    @Test func prunesOnlyConfirmedEmojiOnTheSameTarget() {
        // ❤️ confirmed (no me in summary) → dropped; 👍 still mine → kept.
        let summary = TimelineReactionSummaryFfi(
            byEmoji: [TimelineReactionEmojiFfi(emoji: "👍", senders: [me])],
            userReactions: []
        )
        let pruned = ConversationViewModel.prunedConfirmedOptimisticReactionRemovals(
            [
                removal(emoji: "❤️", sender: me, target: target),
                removal(emoji: "👍", sender: me, target: target),
            ],
            target: target, summary: summary, me: me
        )
        #expect(pruned == [removal(emoji: "👍", sender: me, target: target)])
    }

    @Test func returnsInputUnchangedWhenMeIsEmpty() {
        let summary = TimelineReactionSummaryFfi(byEmoji: [], userReactions: [])
        let input: Set<ConversationViewModel.ReactionRemoval> = [removal(emoji: "❤️", sender: me, target: target)]
        let pruned = ConversationViewModel.prunedConfirmedOptimisticReactionRemovals(
            input, target: target, summary: summary, me: ""
        )
        #expect(pruned == input)
    }
}

/// #380 — target-local reaction tally recomputation should only need the
/// changed target's summary plus optimistic edits that actually point at it.
struct ReactionTargetTallyTests {
    private let me = String(repeating: "1", count: 64)
    private let other = String(repeating: "2", count: 64)
    private let target = String(repeating: "a", count: 64)
    private let otherTarget = String(repeating: "b", count: 64)
    private let groupId = String(repeating: "c", count: 64)

    private func optimisticReaction(
        id: String,
        emoji: String,
        sender: String,
        target: String,
        recordedAt: UInt64 = 1
    ) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: id,
            direction: "sent",
            groupIdHex: groupId,
            sender: sender,
            plaintext: emoji,
            kind: MessageSemantics.kindReaction,
            tags: [MessageTagFfi(values: [MessageSemantics.eventRefTag, target])],
            recordedAt: recordedAt,
            receivedAt: recordedAt
        )
    }

    @Test func computesTalliesForOneTargetFromMatchingOptimisticEditsOnly() {
        let matchingOptimistic = optimisticReaction(
            id: "matching",
            emoji: "🔥",
            sender: me,
            target: target
        )
        let unrelatedOptimistic = optimisticReaction(
            id: "unrelated",
            emoji: "👀",
            sender: me,
            target: otherTarget
        )
        let deletedOptimistic = optimisticReaction(
            id: "deleted",
            emoji: "👀",
            sender: other,
            target: target
        )
        let summary = TimelineReactionSummaryFfi(
            byEmoji: [
                TimelineReactionEmojiFfi(emoji: "👍", senders: [me, other]),
                TimelineReactionEmojiFfi(emoji: "🔥", senders: [other]),
            ],
            userReactions: []
        )

        let tallies = ConversationViewModel.reactionTallies(
            for: target,
            summary: summary,
            optimisticRemovals: [
                ConversationViewModel.ReactionRemoval(targetMessageIdHex: target, emoji: "👍", sender: me),
                ConversationViewModel.ReactionRemoval(targetMessageIdHex: otherTarget, emoji: "🔥", sender: other),
            ],
            optimisticRecords: [
                matchingOptimistic.messageIdHex: matchingOptimistic,
                unrelatedOptimistic.messageIdHex: unrelatedOptimistic,
                deletedOptimistic.messageIdHex: deletedOptimistic,
            ],
            deletedMessageIds: [deletedOptimistic.messageIdHex],
            me: me
        )

        #expect(tallies == [
            ConversationViewModel.ReactionTally(emoji: "🔥", count: 2, mine: true),
            ConversationViewModel.ReactionTally(emoji: "👍", count: 1, mine: false),
        ])
    }

    @Test func removingTheLastSenderReturnsNoTallies() {
        let summary = TimelineReactionSummaryFfi(
            byEmoji: [TimelineReactionEmojiFfi(emoji: "👍", senders: [me])],
            userReactions: []
        )

        let tallies = ConversationViewModel.reactionTallies(
            for: target,
            summary: summary,
            optimisticRemovals: [ConversationViewModel.ReactionRemoval(
                targetMessageIdHex: target,
                emoji: "👍",
                sender: me
            )],
            optimisticRecords: [:],
            deletedMessageIds: [],
            me: me
        )

        #expect(tallies.isEmpty)
    }

    @MainActor
    @Test func projectionDeltaRecomputeMatchesFullRebuildAndKeepsUnrelatedTarget() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: testGroup()
        )
        let unrelatedTally = [ConversationViewModel.ReactionTally(emoji: "👀", count: 1, mine: false)]

        viewModel.applyTimelinePage(
            TimelinePageFfi(
                messages: [
                    timelineRecord(messageIdHex: target, timelineAt: 1),
                    timelineRecord(
                        messageIdHex: otherTarget,
                        timelineAt: 2,
                        reactions: reactionSummary(emoji: "👀", senders: [other])
                    ),
                ],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
            placement: .window
        )
        #expect(viewModel.reactions(for: otherTarget) == unrelatedTally)

        viewModel.applyTimelineSubscriptionUpdate(.projection(update: projectionUpdate(changes: [
            .upsert(
                trigger: .reactionAdded,
                message: timelineRecord(
                    messageIdHex: target,
                    timelineAt: 1,
                    reactions: reactionSummary(emoji: "👍", senders: [other])
                )
            ),
        ])))
        let targetedAfterAdd = viewModel.reactions
        #expect(targetedAfterAdd[target] == [
            ConversationViewModel.ReactionTally(emoji: "👍", count: 1, mine: false)
        ])
        #expect(targetedAfterAdd[otherTarget] == unrelatedTally)
        #expect(viewModel.forceFullReactionRecomputeForTesting() == targetedAfterAdd)

        viewModel.applyTimelineSubscriptionUpdate(.projection(update: projectionUpdate(changes: [
            .upsert(
                trigger: .reactionRemoved,
                message: timelineRecord(
                    messageIdHex: target,
                    timelineAt: 1,
                    reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: [])
                )
            ),
        ])))
        let targetedAfterRemove = viewModel.reactions
        #expect(targetedAfterRemove[target] == nil)
        #expect(targetedAfterRemove[otherTarget] == unrelatedTally)
        #expect(viewModel.forceFullReactionRecomputeForTesting() == targetedAfterRemove)
    }

    private func reactionSummary(emoji: String, senders: [String]) -> TimelineReactionSummaryFfi {
        TimelineReactionSummaryFfi(
            byEmoji: [TimelineReactionEmojiFfi(emoji: emoji, senders: senders)],
            userReactions: []
        )
    }

    private func projectionUpdate(changes: [TimelineMessageChangeFfi]) -> RuntimeProjectionUpdateFfi {
        RuntimeProjectionUpdateFfi(
            accountIdHex: me,
            accountLabel: "",
            update: TimelineProjectionUpdateFfi(
                groupIdHex: groupId,
                messages: [],
                changes: changes,
                chatListRow: nil,
                chatListTrigger: .snapshotRefresh
            )
        )
    }

    private func timelineRecord(
        messageIdHex: String,
        timelineAt: UInt64,
        reactions: TimelineReactionSummaryFfi = TimelineReactionSummaryFfi(byEmoji: [], userReactions: [])
    ) -> TimelineMessageRecordFfi {
        TimelineMessageRecordFfi(
            messageIdHex: messageIdHex,
            sourceMessageIdHex: nil,
            direction: "received",
            groupIdHex: groupId,
            sender: other,
            plaintext: "message \(timelineAt)",
            contentTokens: MarkdownDocumentFfi.emptyDocument,
            kind: MessageSemantics.kindChat,
            tags: [],
            timelineAt: timelineAt,
            receivedAt: timelineAt,
            replyToMessageIdHex: nil,
            replyPreview: nil,
            mediaJson: nil,
            agentTextStreamJson: nil,
            groupSystem: nil,
            reactions: reactions,
            deleted: false,
            deletedByMessageIdHex: nil,
            invalidationStatus: nil
        )
    }

    private func testGroup() -> AppGroupRecordFfi {
        AppGroupRecordFfi(
            groupIdHex: groupId,
            endpoint: "",
            name: "Test Group",
            description: "",
            admins: [],
            relays: [],
            nostrGroupIdHex: "",
            avatarUrl: nil,
            avatarDim: nil,
            avatarThumbhash: nil,
            encryptedMedia: AppGroupEncryptedMediaComponentFfi(
                componentId: 0x8008,
                component: "marmot.group.encrypted-media.v1",
                required: true,
                mediaFormat: MessageSemantics.encryptedMediaVersion,
                allowedLocatorKinds: ["blossom-v1"],
                defaultBlobEndpoints: [
                    AppBlobEndpointFfi(locatorKind: "blossom-v1", baseUrl: "https://blossom.primal.net")
                ]
            ),
            archived: false,
            pendingConfirmation: false,
            welcomerAccountIdHex: nil,
            viaWelcomeMessageIdHex: nil
        )
    }
}

/// #48 — a concurrent "latest" (nil stream id) watch must be guarded so it can't
/// race past the post-await duplicate check and open an orphaned subscription.
struct StreamWatchRaceGuardTests {

    @Test func startWatchingGuardsConcurrentLatestWatch() {
        #expect(!AgentStreamWatchAdmission.canStart(
            streamIdHex: nil,
            activeStreamIds: [],
            latestStreamWatchInFlight: true
        ))
        #expect(AgentStreamWatchAdmission.canStart(
            streamIdHex: nil,
            activeStreamIds: [],
            latestStreamWatchInFlight: false
        ))
        #expect(!AgentStreamWatchAdmission.canStart(
            streamIdHex: "stream-a",
            activeStreamIds: ["stream-a"],
            latestStreamWatchInFlight: false
        ))
        #expect(AgentStreamWatchAdmission.canStart(
            streamIdHex: "stream-b",
            activeStreamIds: ["stream-a"],
            latestStreamWatchInFlight: true
        ))
    }
}

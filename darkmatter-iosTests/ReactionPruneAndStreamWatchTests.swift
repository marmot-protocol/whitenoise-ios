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

/// #48 — a concurrent "latest" (nil stream id) watch must be guarded so it can't
/// race past the post-await duplicate check and open an orphaned subscription.
/// Driven at the source level: startWatching is private and does real I/O.
struct StreamWatchRaceGuardTests {

    @Test func startWatchingGuardsConcurrentLatestWatch() throws {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Conversation/ConversationViewModel.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        #expect(source.contains("private var latestStreamWatchInFlight = false"))
        #expect(source.range(
            of: #"else if latestStreamWatchInFlight \{[\s\S]*?return"#,
            options: .regularExpression
        ) != nil)
    }
}

import Foundation
import Testing
@testable import MarmotKit
@testable import whitenoise_ios

struct ReactionMetadataFittingTests {
    @Test func aChipCannotClearAnotherOwnedOrUnseenReactionKind() {
        let mine = ConversationViewModel.ReactionTally(emoji: "🥾", count: 2, mine: true)
        var other = ConversationViewModel.ReactionTally(emoji: "🎉", count: 1, mine: false)
        #expect(ReactionPillPresentation.canRemoveIndividually("🥾", from: [mine, other], omittedKinds: 0))
        #expect(!ReactionPillPresentation.canRemoveIndividually("🥾", from: [mine, other], omittedKinds: 1))
        other = .init(emoji: "🎉", count: 2, mine: true)
        #expect(!ReactionPillPresentation.canRemoveIndividually("🥾", from: [mine, other], omittedKinds: 0))
    }

    @Test func chipTapUsesTheDisplayedEmojiAndProtectsOtherOwnedKinds() {
        func action(_ emoji: String, mine: Bool = false, omitted: UInt64 = 0, repeatable: Bool = false) -> ReactionPillPresentation.TapAction {
            let tally = ConversationViewModel.ReactionTally(emoji: emoji, count: 2, mine: mine)
            return ReactionPillPresentation.tapAction(for: tally, in: [tally], omittedKinds: omitted) { _ in repeatable }
        }
        #expect(action("❤️") == .toggle)
        #expect(action("1") == .showDetails)
        #expect(action("©") == .showDetails)
        #expect(action("😀" + String(repeating: "\u{0301}", count: 100)) == .showDetails)
        #expect(action(":party:", repeatable: true) == .toggle)
        #expect(action(":party:") == .showDetails)
        #expect(action(":party:", mine: true) == .toggle)
        #expect(action(":party:", mine: true, omitted: 1) == .showDetails)
    }

    @Test func keepsEveryPillWhenTheMetadataRowFits() {
        let fit = ReactionMetadataFitting.fit(
            reactionWidths: [30, 30, 30],
            overflowWidthForHiddenCount: [1: 24, 2: 24, 3: 24],
            footerWidth: 20,
            availableWidth: 124
        )

        #expect(fit == ReactionMetadataFit(visibleReactionCount: 3, hiddenReactionCount: 0))
    }

    @Test func usesTheLargestVisiblePrefixThatFitsBesideOverflowAndFooter() {
        let fit = ReactionMetadataFitting.fit(
            reactionWidths: [30, 30, 30],
            overflowWidthForHiddenCount: [1: 24, 2: 24, 3: 24],
            footerWidth: 20,
            availableWidth: 95
        )

        #expect(fit == ReactionMetadataFit(visibleReactionCount: 1, hiddenReactionCount: 2))
    }

    @Test func aCountedEmojiKeepsItsPlaceWhenTheTimestampLeavesTooLittleWidth() {
        let fit = ReactionMetadataFitting.fit(reactionWidths: [44], overflowWidthForHiddenCount: [1: 34],
                                              footerWidth: 35, availableWidth: 78)
        #expect(fit == ReactionMetadataFit(visibleReactionCount: 1, hiddenReactionCount: 0))
    }

    @Test func aNarrowRowKeepsTheFirstEmojiAndCountsOnlyAdditionalKindsInOverflow() {
        let fit = ReactionMetadataFitting.fit(reactionWidths: [44, 34, 34], overflowWidthForHiddenCount: [5: 34, 6: 34],
                                              footerWidth: 35, availableWidth: 78, preHiddenReactionCount: 3)
        #expect(fit == ReactionMetadataFit(visibleReactionCount: 1, hiddenReactionCount: 5))
    }

    @Test func aSummaryWithoutEmojiRetainsTheOmittedCount() {
        let fit = ReactionMetadataFitting.fit(reactionWidths: [], overflowWidthForHiddenCount: [:],
                                              footerWidth: 35, availableWidth: 20, preHiddenReactionCount: 5)
        #expect(fit == ReactionMetadataFit(visibleReactionCount: 0, hiddenReactionCount: 5))
    }

    @Test func preservesAlreadyHiddenReactionTypesWhenEveryRenderedPillFits() {
        let fit = ReactionMetadataFitting.fit(
            reactionWidths: [30, 30],
            overflowWidthForHiddenCount: [3: 24, 4: 24, 5: 24],
            footerWidth: 20,
            availableWidth: 121,
            preHiddenReactionCount: 3
        )

        #expect(fit == ReactionMetadataFit(visibleReactionCount: 2, hiddenReactionCount: 3))
    }
}

struct MessageClusterProjectionTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    @Test func sameSenderMessagesWithinFiveMinutesShareOneCluster() throws {
        let items = [
            item(id: "01", sender: "alice", timestamp: 100),
            item(id: "02", sender: "alice", timestamp: 200),
            item(id: "03", sender: "alice", timestamp: 500),
        ]

        let result = MessageClusterProjection.presentations(for: items, calendar: calendar)
        let first = try #require(result[items[0].id])
        let middle = try #require(result[items[1].id])
        let last = try #require(result[items[2].id])

        #expect(first.showsSenderName)
        #expect(!first.showsAvatar)
        #expect(!middle.showsSenderName)
        #expect(!middle.showsAvatar)
        #expect(!last.showsSenderName)
        #expect(last.showsAvatar)
        #expect(last.reservesIdentityLane)
    }

    @Test func senderSystemRowsAndOutgoingMessagesBreakClusters() throws {
        let first = item(id: "11", sender: "alice", timestamp: 100)
        let otherSender = item(id: "12", sender: "bob", timestamp: 101)
        let beforeSystem = item(id: "13", sender: "alice", timestamp: 102)
        let system = TimelineItem.systemEvent(id: "break", event: .rosterChanged, timestamp: 103)
        let afterSystem = item(id: "14", sender: "alice", timestamp: 104)
        let outgoing = item(id: "15", sender: "me", timestamp: 105, direction: "sent")
        let secondOutgoing = item(id: "17", sender: "me", timestamp: 105, direction: "sent")
        let afterOutgoing = item(id: "16", sender: "alice", timestamp: 106)
        let items = [first, otherSender, beforeSystem, system, afterSystem, outgoing, secondOutgoing, afterOutgoing]

        let result = MessageClusterProjection.presentations(for: items, calendar: calendar)

        for incoming in [first, otherSender, beforeSystem, afterSystem, afterOutgoing] {
            let presentation = try #require(result[incoming.id])
            #expect(presentation.showsSenderName)
            #expect(presentation.showsAvatar)
        }
        let own = try #require(result[outgoing.id])
        #expect(own.startsCluster)
        #expect(result[secondOutgoing.id]?.startsCluster == false)
        #expect(!own.endsCluster)
        #expect(result[secondOutgoing.id]?.endsCluster == true)
        #expect(!own.reservesIdentityLane && !own.showsAvatar && !own.showsSenderName)
    }

    @Test func ownMessagesFromTwoDevicesShareAnOutgoingCluster() throws {
        let me = hex("ab")
        let sent = item(id: "01", sender: me, timestamp: 100, direction: "sent")
        let linkedDevice = item(id: "02", sender: me, timestamp: 101)
        let result = MessageClusterProjection.presentations(for: [sent, linkedDevice], myAccountId: me, calendar: calendar)
        let first = try #require(result[sent.id])
        let last = try #require(result[linkedDevice.id])

        #expect(!first.endsCluster && !last.startsCluster && last.endsCluster)
        #expect(!last.reservesIdentityLane && !last.showsSenderName && !last.showsAvatar)
    }

    @Test func visibleUnreadDividerSplitsAnOtherwiseContinuousCluster() throws {
        let timeline = (1...3).map { item(id: "message\($0)", sender: "maya", timestamp: UInt64($0)) }
        let clusters = MessageClusterProjection.presentations(for: timeline, calendar: calendar)
        let preceding = try #require(clusters[timeline[0].id])
        let unread = try #require(clusters[timeline[1].id])
        let lastRead = preceding.atUnreadBoundary(rowID: timeline[0].id, timeline: timeline, firstUnreadIndex: 1)
        #expect(lastRead.endsCluster && lastRead.showsAvatar)
        #expect(unread.atUnreadBoundary(rowID: timeline[1].id, timeline: timeline, firstUnreadIndex: 1).showsSenderName)
        #expect(preceding.atUnreadBoundary(rowID: timeline[0].id, timeline: timeline, firstUnreadIndex: nil) == preceding)
    }

    @Test func nonterminalRowsKeepActionableMetadata() {
        var cluster = MessageClusterPresentation.none
        cluster.endsCluster = false
        for status: MessageStatus in [.sending, .failed] {
            #expect(cluster.showsFooter(status: status, isDeleted: false, isEdited: false, reported: false))
        }
        #expect(!cluster.showsFooter(status: .received, isDeleted: false, isEdited: false, reported: false))
        #expect(cluster.showsFooter(status: .received, isDeleted: false, isEdited: false, reported: true))
        #expect(!cluster.showsFooter(status: .sent, isDeleted: false, isEdited: false, reported: false))
    }

    @Test func calendarDayAndFiveMinuteBoundaryAreDeterministic() throws {
        let beforeMidnight = item(id: "21", sender: "alice", timestamp: 86_390)
        let afterMidnight = item(id: "22", sender: "alice", timestamp: 86_410)
        let atLimit = item(id: "23", sender: "alice", timestamp: 86_710)
        let beyondLimit = item(id: "24", sender: "alice", timestamp: 87_011)
        let items = [beforeMidnight, afterMidnight, atLimit, beyondLimit]

        let result = MessageClusterProjection.presentations(for: items, calendar: calendar)

        #expect(try #require(result[beforeMidnight.id]).showsAvatar)
        #expect(try #require(result[afterMidnight.id]).showsSenderName)
        #expect(!(try #require(result[atLimit.id])).showsSenderName)
        #expect(try #require(result[atLimit.id]).showsAvatar)
        #expect(try #require(result[beyondLimit.id]).showsSenderName)
    }

    private func item(
        id: String,
        sender: String,
        timestamp: UInt64,
        direction: String = "received"
    ) -> TimelineItem {
        TimelineItem.message(AppMessageRecordFfi(
            messageIdHex: String(repeating: id, count: 32),
            direction: direction,
            groupIdHex: String(repeating: "aa", count: 32),
            sender: sender,
            plaintext: "message",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: timestamp,
            receivedAt: timestamp
        ))
    }
}

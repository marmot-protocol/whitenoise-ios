import Foundation
import Testing
@testable import whitenoise_ios

struct ConversationSearchEngineTests {

    private func entry(_ id: String, _ text: String) -> ConversationSearchEntry {
        ConversationSearchEntry(itemId: "msg:\(id)", messageIdHex: id, text: text)
    }

    @Test func excerptRevealsAMatchingSuffixOrLineInTheOriginalSpelling() throws {
        let file = String(repeating: "meeting-", count: 30) + "Résumé.pdf"
        #expect(ConversationSearchEngine.excerpt(in: file, matching: "resume", leadingContext: 0) == "…Résumé.pdf")
        let body = Array(repeating: "An earlier line", count: 90).joined(separator: "\n") + "\nThe Meeting is today."
        let excerpt = try #require(ConversationSearchEngine.excerpt(in: body, matching: "meeting", leadingContext: 6))
        #expect(excerpt.contains("The Meeting is today."))
        #expect(!excerpt.contains("\n"))
        #expect(excerpt.count < 40)
    }

    // MARK: - Match indexing

    @Test func matchesKeepTimelineOrderAndSkipNonMatchingRows() {
        let entries = [
            entry("a", "we should meet on Tuesday"),
            entry("b", "no relation at all"),
            entry("c", "another meeting invite"),
            entry("d", "MEET me outside")
        ]

        let matches = ConversationSearchEngine.matches(for: "meet", in: entries)

        #expect(matches.map(\.messageIdHex) == ["a", "c", "d"])
        #expect(matches.map(\.itemId) == ["msg:a", "msg:c", "msg:d"])
    }

    @Test func labelsMatchIndependentlyAndCountTheirMessageOnce() {
        let file = ConversationSearchEntry(itemId: "row", messageIdHex: "id", text: "Plan",
            labels: ["Maya", "Maya’s itinerary.pdf"])
        #expect(ConversationSearchEngine.matches(for: "maya", in: [file]).map(\.itemId) == ["row"])
        #expect(ConversationSearchEngine.matches(for: "Plan Maya", in: [file]).isEmpty)
    }

    @Test func matchesAreCaseInsensitive() {
        let entries = [entry("a", "Hello World")]

        #expect(ConversationSearchEngine.matches(for: "hello", in: entries).count == 1)
        #expect(ConversationSearchEngine.matches(for: "WORLD", in: entries).count == 1)
    }

    @Test func matchesAreDiacriticInsensitive() {
        let entries = [entry("a", "café rendezvous"), entry("b", "resume attached")]

        #expect(ConversationSearchEngine.matches(for: "cafe", in: entries).map(\.messageIdHex) == ["a"])
        #expect(ConversationSearchEngine.matches(for: "résumé", in: entries).map(\.messageIdHex) == ["b"])
    }

    @Test func blankOrWhitespaceQueryYieldsNoMatches() {
        let entries = [entry("a", "anything")]

        #expect(ConversationSearchEngine.matches(for: "", in: entries).isEmpty)
        #expect(ConversationSearchEngine.matches(for: "   \n", in: entries).isEmpty)
        #expect(ConversationSearchEngine.normalizedQuery("  hi  ") == "hi")
        #expect(ConversationSearchEngine.normalizedQuery(" \t ") == nil)
    }

    @Test func queryIsTrimmedBeforeMatching() {
        let entries = [entry("a", "hello world")]

        #expect(ConversationSearchEngine.matches(for: "  hello  ", in: entries).count == 1)
    }

    // MARK: - Cursor arithmetic

    @Test func initialIndexLandsOnNewestMatch() {
        #expect(ConversationSearchEngine.initialIndex(matchCount: 3) == 2)
        #expect(ConversationSearchEngine.initialIndex(matchCount: 0) == nil)
    }

    @Test func olderNavigationStepsTowardIndexZero() {
        #expect(ConversationSearchEngine.olderIndex(from: 2, matchCount: 3) == 1)
        #expect(ConversationSearchEngine.olderIndex(from: 1, matchCount: 3) == 0)
    }

    @Test func olderNavigationWrapsFromOldestToNewest() {
        #expect(ConversationSearchEngine.olderIndex(from: 0, matchCount: 3) == 2)
    }

    @Test func newerNavigationStepsTowardNewest() {
        #expect(ConversationSearchEngine.newerIndex(from: 0, matchCount: 3) == 1)
        #expect(ConversationSearchEngine.newerIndex(from: 1, matchCount: 3) == 2)
    }

    @Test func newerNavigationWrapsFromNewestToOldest() {
        #expect(ConversationSearchEngine.newerIndex(from: 2, matchCount: 3) == 0)
    }

    @Test func navigationWithoutCursorLandsOnNewest() {
        #expect(ConversationSearchEngine.olderIndex(from: nil, matchCount: 3) == 2)
        #expect(ConversationSearchEngine.newerIndex(from: nil, matchCount: 3) == 2)
    }

    @Test func navigationWithNoMatchesYieldsNoCursor() {
        #expect(ConversationSearchEngine.olderIndex(from: nil, matchCount: 0) == nil)
        #expect(ConversationSearchEngine.newerIndex(from: 0, matchCount: 0) == nil)
    }

    @Test func singleMatchWrapsOntoItself() {
        #expect(ConversationSearchEngine.olderIndex(from: 0, matchCount: 1) == 0)
        #expect(ConversationSearchEngine.newerIndex(from: 0, matchCount: 1) == 0)
    }

    // MARK: - Reanchoring and counter

    @Test func reanchoredIndexFindsRowAfterOlderWindowGrowth() {
        let before = [
            ConversationSearchMatch(itemId: "msg:b", messageIdHex: "b")
        ]
        let after = [
            ConversationSearchMatch(itemId: "msg:a", messageIdHex: "a"),
            ConversationSearchMatch(itemId: "msg:b", messageIdHex: "b")
        ]

        #expect(ConversationSearchEngine.reanchoredIndex(of: before[0].itemId, in: after) == 1)
        #expect(ConversationSearchEngine.reanchoredIndex(of: "msg:gone", in: after) == nil)
        #expect(ConversationSearchEngine.reanchoredIndex(of: nil, in: after) == nil)
    }

    @Test func displayPositionCountsFromNewestMatch() {
        #expect(ConversationSearchEngine.displayPosition(index: 2, matchCount: 3) == 1)
        #expect(ConversationSearchEngine.displayPosition(index: 0, matchCount: 3) == 3)
    }
}

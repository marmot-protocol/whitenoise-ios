import Foundation
import Testing
@testable import whitenoise_ios

@MainActor
struct ConversationSearchModelTests {

    /// A fake loaded window: entries in timeline order plus an older backlog
    /// that pages in one slice per `loadOlderPage` call.
    @MainActor
    private final class TimelineStub {
        var loaded: [ConversationSearchEntry]
        var olderBacklog: [[ConversationSearchEntry]]
        private(set) var pagesServed = 0

        init(loaded: [ConversationSearchEntry], olderBacklog: [[ConversationSearchEntry]] = []) {
            self.loaded = loaded
            self.olderBacklog = olderBacklog
        }

        func attach(to model: ConversationSearchModel) {
            model.entriesProvider = { [weak self] in self?.loaded ?? [] }
            model.hasMoreBefore = { [weak self] in !(self?.olderBacklog.isEmpty ?? true) }
            model.loadOlderPage = { [weak self] in
                guard let self, !self.olderBacklog.isEmpty else { return }
                self.pagesServed += 1
                self.loaded = self.olderBacklog.removeLast() + self.loaded
            }
        }
    }

    private static func entry(_ id: String, _ text: String) -> ConversationSearchEntry {
        ConversationSearchEntry(itemId: "msg:\(id)", messageIdHex: id, text: text)
    }

    @Test func queryChangeIndexesMatchesAndTargetsNewestMatch() {
        let stub = TimelineStub(loaded: [
            Self.entry("a", "meet at noon"),
            Self.entry("b", "unrelated"),
            Self.entry("c", "team meeting")
        ])
        let model = ConversationSearchModel()
        stub.attach(to: model)
        model.activate()

        model.query = "meet"

        #expect(model.matches.map(\.messageIdHex) == ["a", "c"])
        #expect(model.currentMatch?.messageIdHex == "c")
        #expect(model.displayPosition == 1)
        #expect(model.scrollRequest?.itemId == "msg:c")
    }

    @Test func pollDeadlineScrollsOnlyWhenTheSelectedSearchResultChanges() {
        let stub = TimelineStub(loaded: [Self.entry("a", "Select one"), Self.entry("b", "Select one")])
        let model = ConversationSearchModel()
        stub.attach(to: model)
        model.activate()
        model.query = "Select one"
        let originalRequest = model.scrollRequest

        model.refreshAfterSearchableContentChange()
        #expect(model.scrollRequest == originalRequest)
        stub.loaded[1] = Self.entry("b", "Final results")
        model.refreshAfterSearchableContentChange()
        #expect(model.scrollRequest?.itemId == "msg:a")
        #expect(model.matchingItemIDs == ["msg:a"])
    }

    @Test func aNewPageCanAddASearchMatchWithoutTakingTheViewport() {
        let stub = TimelineStub(loaded: [Self.entry("a", "Hello")])
        let model = ConversationSearchModel()
        stub.attach(to: model)
        model.activate()
        model.query = "receipt"
        stub.loaded.insert(Self.entry("older", "receipt"), at: 0)
        model.refreshAfterSearchableContentChange { $0 == "a" }
        #expect(model.currentMatch?.itemId == "msg:older")
        #expect(model.scrollRequest == nil)
    }

    @Test func newSenderMatchScrollsWhileAnOlderQueryFinishesPaging() async {
        let stub = TimelineStub(loaded: [Self.entry("a", "Hello")], olderBacklog: [[]])
        let model = ConversationSearchModel()
        stub.attach(to: model)
        model.activate()
        model.query = "first query"
        model.loadOlderPage = { [weak model] in
            guard let model else { return }
            model.query = "Alice"
            stub.loaded[0].labels = ["Alice"]
            model.refreshAfterSearchableContentChange()
        }
        await model.searchOlder()
        #expect(model.currentMatch?.itemId == "msg:a")
        #expect(model.scrollRequest?.itemId == "msg:a")
    }

    @Test func olderNavigationMovesThroughLoadedMatchesThenWraps() async {
        let stub = TimelineStub(loaded: [
            Self.entry("a", "meet at noon"),
            Self.entry("b", "team meeting")
        ])
        let model = ConversationSearchModel()
        stub.attach(to: model)
        model.activate()
        model.query = "meet"
        #expect(model.currentMatch?.messageIdHex == "b")

        await model.goToOlderMatch()
        #expect(model.currentMatch?.messageIdHex == "a")
        #expect(model.displayPosition == 2)

        // No older history, so stepping past the oldest match wraps to newest.
        await model.goToOlderMatch()
        #expect(model.currentMatch?.messageIdHex == "b")
        #expect(model.displayPosition == 1)
    }

    @Test func newerNavigationWrapsFromNewestToOldest() {
        let stub = TimelineStub(loaded: [
            Self.entry("a", "meet at noon"),
            Self.entry("b", "team meeting")
        ])
        let model = ConversationSearchModel()
        stub.attach(to: model)
        model.activate()
        model.query = "meet"
        #expect(model.currentMatch?.messageIdHex == "b")

        model.goToNewerMatch()
        #expect(model.currentMatch?.messageIdHex == "a")

        model.goToNewerMatch()
        #expect(model.currentMatch?.messageIdHex == "b")
    }

    @Test func olderNavigationPagesHistoryInUntilAMatchAppears() async {
        let stub = TimelineStub(
            loaded: [Self.entry("z", "meet me later")],
            olderBacklog: [
                [Self.entry("a", "old meeting notes")],
                [Self.entry("b", "nothing relevant")]
            ]
        )
        let model = ConversationSearchModel()
        stub.attach(to: model)
        model.activate()
        model.query = "meet"
        #expect(model.currentMatch?.messageIdHex == "z")

        await model.goToOlderMatch()

        // Page 1 ("b") had no hit, page 2 ("a") did, both within the budget.
        #expect(stub.pagesServed == 2)
        #expect(model.currentMatch?.messageIdHex == "a")
        #expect(model.matches.map(\.messageIdHex) == ["a", "z"])
        #expect(model.scrollRequest?.itemId == "msg:a")
    }

    @Test func olderNavigationStopsAtThePagingBudget() async {
        let backlog = (0..<10).map { [Self.entry("old-\($0)", "nothing relevant")] }
        let stub = TimelineStub(
            loaded: [Self.entry("z", "meet me later")],
            olderBacklog: backlog
        )
        let model = ConversationSearchModel()
        stub.attach(to: model)
        model.activate()
        model.query = "meet"

        await model.goToOlderMatch()

        #expect(stub.pagesServed == ConversationSearchPagingPolicy.maxOlderPagesPerStep)
        // Cursor stays on the loaded match, the continuation stays offered.
        #expect(model.currentMatch?.messageIdHex == "z")
        #expect(model.showsOlderContinuation)
    }

    @Test func searchOlderContinuationRunsAnotherBudgetedStep() async {
        let backlog = (0..<4).map { [Self.entry("old-\($0)", "nothing relevant")] }
        let stub = TimelineStub(
            loaded: [Self.entry("z", "meet me later")],
            olderBacklog: backlog
        )
        let model = ConversationSearchModel()
        stub.attach(to: model)
        model.activate()
        model.query = "meet"

        await model.searchOlder()
        #expect(stub.pagesServed == ConversationSearchPagingPolicy.maxOlderPagesPerStep)

        await model.searchOlder()
        #expect(stub.pagesServed == 4)
        #expect(!model.showsOlderContinuation)
    }

    @Test func olderNavigationWrapsWhenPagedHistoryIsExhaustedWithoutAHit() async {
        let stub = TimelineStub(
            loaded: [
                Self.entry("a", "meet at noon"),
                Self.entry("b", "team meeting")
            ],
            olderBacklog: [[Self.entry("old", "nothing relevant")]]
        )
        let model = ConversationSearchModel()
        stub.attach(to: model)
        model.activate()
        model.query = "meet"
        await model.goToOlderMatch()
        #expect(model.currentMatch?.messageIdHex == "a")

        // The one older page has no hit, so the step exhausts history and wraps.
        await model.goToOlderMatch()

        #expect(stub.pagesServed == 1)
        #expect(model.currentMatch?.messageIdHex == "b")
    }

    @Test func timelineChangeRefreshKeepsTheCursorOnTheSameRow() {
        let stub = TimelineStub(loaded: [
            Self.entry("a", "meet at noon"),
            Self.entry("b", "team meeting")
        ])
        let model = ConversationSearchModel()
        stub.attach(to: model)
        model.activate()
        model.query = "meet"
        model.goToNewerMatch()
        #expect(model.currentMatch?.messageIdHex == "a")

        stub.loaded.append(Self.entry("c", "another meetup"))
        model.refreshAfterTimelineChange()

        #expect(model.matches.map(\.messageIdHex) == ["a", "b", "c"])
        #expect(model.currentMatch?.messageIdHex == "a")
        #expect(model.displayPosition == 3)
    }

    @Test func endClearsAllSearchState() {
        let stub = TimelineStub(loaded: [Self.entry("a", "meet at noon")])
        let model = ConversationSearchModel()
        stub.attach(to: model)
        model.activate()
        model.query = "meet"
        #expect(!model.matches.isEmpty)

        model.end()

        #expect(!model.isActive)
        #expect(model.query.isEmpty)
        #expect(model.matches.isEmpty)
        #expect(model.currentIndex == nil)
        #expect(model.scrollRequest == nil)
        #expect(!model.isPagingOlder)
    }

    @Test func queryEditsWhileInactiveDoNotIndexMatches() {
        let stub = TimelineStub(loaded: [Self.entry("a", "meet at noon")])
        let model = ConversationSearchModel()
        stub.attach(to: model)

        model.query = "meet"

        #expect(model.matches.isEmpty)
        #expect(model.scrollRequest == nil)
    }
}

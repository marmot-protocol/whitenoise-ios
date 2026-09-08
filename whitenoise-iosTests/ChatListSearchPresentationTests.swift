import Testing

@testable import whitenoise_ios

@MainActor
struct ChatListSearchPresentationTests {
    /// Chats is a navigation-stack root, so an exit that leaves any part of
    /// this set behind is the no-way-out bug.
    private func expectFullyExited(
        _ search: ChatListSearchPresentation,
        _ comment: Comment
    ) {
        #expect(!search.isActive, comment)
        #expect(search.query.isEmpty, comment)
        #expect(!search.isFiltering, comment)
    }

    @Test func startsInactiveSoALaunchShowsTheOrdinaryToolbar() {
        expectFullyExited(ChatListSearchPresentation(), "fresh state")
    }

    @Test func activationShowsTheBarThatCarriesTheExit() {
        let search = ChatListSearchPresentation()

        search.activate()

        #expect(search.isActive)
        #expect(search.query.isEmpty)
    }

    @Test func repeatedSearchTapsKeepTheLiveFieldAndItsQuery() {
        let search = ChatListSearchPresentation()
        search.activate()
        search.query = "alice"

        search.activate()
        search.activate()

        #expect(search.isActive)
        #expect(search.query == "alice")
    }

    @Test func exitClearsEverything() {
        let search = ChatListSearchPresentation()
        search.activate()
        search.query = "alice"

        search.exit()

        expectFullyExited(search, "explicit exit")
    }

    @Test func exitIsIdempotentAcrossOverlappingDismissals() {
        let search = ChatListSearchPresentation()
        search.activate()
        search.query = "alice"

        // The ✕ and a result tap can land in the same update.
        search.exit()
        search.exit()

        expectFullyExited(search, "overlapping dismissals")
    }

    @Test func exitingWhileAlreadyInactiveChangesNothing() {
        let search = ChatListSearchPresentation()

        search.exit()

        expectFullyExited(search, "exit from rest")
    }

    @Test func reactivationAfterExitStartsFromAnEmptyQuery() {
        let search = ChatListSearchPresentation()
        search.activate()
        search.query = "alice"
        search.exit()

        search.activate()

        #expect(search.isActive)
        #expect(search.query.isEmpty)
    }

    @Test(arguments: ["", "   ", "\n\t "])
    func blankQueriesDoNotFilter(_ query: String) {
        let search = ChatListSearchPresentation()
        search.activate()
        search.query = query

        #expect(search.isActive)
        #expect(!search.isFiltering)
        #expect(search.trimmedQuery.isEmpty)
    }

    @Test func surroundingWhitespaceIsTrimmedForFiltering() {
        let search = ChatListSearchPresentation()
        search.activate()
        search.query = "  alice  "

        #expect(search.isFiltering)
        #expect(search.trimmedQuery == "alice")
    }

    /// Clearing the query keeps the bar up so the field stays reachable.
    @Test func clearingTheQueryDoesNotExitSearch() {
        let search = ChatListSearchPresentation()
        search.activate()
        search.query = "alice"

        search.query = ""

        #expect(search.isActive)
        #expect(!search.isFiltering)
    }
}

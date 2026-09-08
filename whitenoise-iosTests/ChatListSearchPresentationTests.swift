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
        #expect(!search.isMounted, comment)
        #expect(!search.isPresented, comment)
        #expect(search.query.isEmpty, comment)
        #expect(!search.isActive, comment)
        #expect(!search.isFiltering, comment)
    }

    @Test func startsInactiveSoALaunchShowsTheOrdinaryToolbar() {
        expectFullyExited(ChatListSearchPresentation(), "fresh state")
    }

    @Test func activationMountsBeforeTheFieldCanBePresented() {
        let search = ChatListSearchPresentation()

        search.activate()
        #expect(search.isMounted)
        #expect(!search.isPresented)
        #expect(search.isActive)

        search.present()
        #expect(search.isPresented)
    }

    @Test func repeatedSearchTapsKeepTheLiveFieldAndItsQuery() {
        let search = ChatListSearchPresentation()
        search.activate()
        search.present()
        search.query = "alice"

        search.activate()
        search.activate()

        #expect(search.isMounted)
        #expect(search.isPresented)
        #expect(search.query == "alice")
    }

    @Test func explicitExitClearsEverything() {
        let search = ChatListSearchPresentation()
        search.activate()
        search.present()
        search.query = "alice"

        search.exit()

        expectFullyExited(search, "explicit exit")
    }

    @Test func nativeCancelConvergesOnTheSameCleanup() {
        let search = ChatListSearchPresentation()
        search.activate()
        search.present()
        search.query = "alice"

        // What `searchable(isPresented:)` writes when the user taps Cancel.
        search.isPresented = false
        search.reconcileNativePresentation()

        expectFullyExited(search, "native dismissal")
    }

    @Test func reconcilingWhileStillPresentedIsNotAnExit() {
        let search = ChatListSearchPresentation()
        search.activate()
        search.present()
        search.query = "alice"

        search.reconcileNativePresentation()

        #expect(search.isPresented)
        #expect(search.query == "alice")
    }

    @Test func exitIsIdempotentAcrossOverlappingDismissals() {
        let search = ChatListSearchPresentation()
        search.activate()
        search.present()
        search.query = "alice"

        // Navigating into a result and the system's own dismissal can both
        // land in the same update.
        search.exit()
        search.reconcileNativePresentation()
        search.exit()

        expectFullyExited(search, "overlapping dismissals")
    }

    @Test func interruptedActivationStaysEscapable() {
        let search = ChatListSearchPresentation()

        // The activation task was cancelled before it could present.
        search.activate()

        #expect(search.isActive)
        #expect(!search.isFiltering)

        search.exit()
        expectFullyExited(search, "exit after interrupted activation")
    }

    @Test func presentIsRefusedWhileUnmounted() {
        let search = ChatListSearchPresentation()

        search.present()

        expectFullyExited(search, "present without mount")
    }

    @Test func reactivationAfterExitStartsFromAnEmptyQuery() {
        let search = ChatListSearchPresentation()
        search.activate()
        search.present()
        search.query = "alice"
        search.exit()

        search.activate()
        search.present()

        #expect(search.isPresented)
        #expect(search.query.isEmpty)
    }

    @Test(arguments: ["", "   ", "\n\t "])
    func blankQueriesDoNotFilter(_ query: String) {
        let search = ChatListSearchPresentation()
        search.activate()
        search.present()
        search.query = query

        #expect(!search.isFiltering)
        #expect(search.trimmedQuery.isEmpty)
    }

    @Test func surroundingWhitespaceIsTrimmedForFiltering() {
        let search = ChatListSearchPresentation()
        search.activate()
        search.present()
        search.query = "  alice  "

        #expect(search.isFiltering)
        #expect(search.trimmedQuery == "alice")
    }
}

import Foundation
import Testing
@testable import whitenoise_ios

struct RecipientBrowseStateTests {
    private func state(
        candidateCount: Int = 0,
        isLoadingDirectory: Bool = false,
        directoryLoadError: String? = nil,
        isSearchingNetwork: Bool = false,
        trimmedQuery: String = ""
    ) -> RecipientBrowseState {
        .resolve(
            candidateCount: candidateCount,
            isLoadingDirectory: isLoadingDirectory,
            directoryLoadError: directoryLoadError,
            isSearchingNetwork: isSearchingNetwork,
            trimmedQuery: trimmedQuery
        )
    }

    @Test func anyCandidateOutranksEveryOtherSignal() {
        #expect(
            state(
                candidateCount: 1,
                isLoadingDirectory: true,
                directoryLoadError: "Couldn't load chats",
                isSearchingNetwork: true,
                trimmedQuery: "ali"
            ) == .people
        )
    }

    @Test func emptyDirectoryReportsLoadingBeforeItsError() {
        #expect(
            state(isLoadingDirectory: true, directoryLoadError: "Couldn't load chats") == .loading
        )
    }

    @Test func settledEmptyDirectoryReportsItsError() {
        #expect(state(directoryLoadError: "Couldn't load chats") == .loadFailed(message: "Couldn't load chats"))
    }

    /// A running relay search must not flash an empty state before answering.
    @Test func runningSearchSuppressesBothEmptyStates() {
        #expect(state(isSearchingNetwork: true) == .awaitingSearch)
        #expect(state(isSearchingNetwork: true, trimmedQuery: "ali") == .awaitingSearch)
    }

    @Test func settledBlankQueryReportsAnEmptyDirectory() {
        #expect(state() == .noPeople)
    }

    @Test func settledQueryReportsItsOwnMissedSearch() {
        #expect(state(trimmedQuery: "ali") == .noMatches(query: "ali"))
    }
}

struct RecipientQueryModeTests {
    @Test func blankQueryBrowses() {
        #expect(RecipientQueryMode.mode(isBlank: true, isIdentifierQuery: false) == .browse)
    }

    /// A stale resolution outliving the text that produced it must not put a
    /// cleared field back into the resolver.
    @Test func blankQueryBrowsesEvenWhenStillFlaggedAsAnIdentifier() {
        #expect(RecipientQueryMode.mode(isBlank: true, isIdentifierQuery: true) == .browse)
    }

    @Test func identifierQueryResolves() {
        #expect(RecipientQueryMode.mode(isBlank: false, isIdentifierQuery: true) == .resolve)
    }

    @Test func freeTextQuerySearches() {
        #expect(RecipientQueryMode.mode(isBlank: false, isIdentifierQuery: false) == .search)
    }
}

struct RecipientPasteboardTests {
    @Test func emptyClipboardIsRejected() {
        #expect(RecipientPasteboard.profileQuery(from: nil) == nil)
        #expect(RecipientPasteboard.profileQuery(from: "") == nil)
        #expect(RecipientPasteboard.profileQuery(from: "  \n ") == nil)
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        #expect(RecipientPasteboard.profileQuery(from: "  npub1abc\n") == "npub1abc")
    }

    @Test func aPastedDocumentIsRejectedRatherThanClassified() {
        let atLimit = String(repeating: "n", count: RecipientPasteboard.maxLength)
        #expect(RecipientPasteboard.profileQuery(from: atLimit) == atLimit)
        #expect(RecipientPasteboard.profileQuery(from: atLimit + "n") == nil)
    }
}

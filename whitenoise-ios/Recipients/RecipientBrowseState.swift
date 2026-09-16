import Foundation

/// What a recipient people list has to show right now. New Message, the group
/// picker, and Add Members all browse the same directory against the same
/// relay search, so the precedence between "still loading", "the relay search
/// hasn't answered yet", and "nothing matched" is decided once, here, instead
/// of three times inside three view bodies.
nonisolated enum RecipientBrowseState: Equatable {
    case loading
    case loadFailed(message: String)
    /// Nothing local matched and the relay search is still running: an empty
    /// state now would only flash before the results land.
    case awaitingSearch
    case noPeople
    case noMatches(query: String)
    case people

    static func resolve(
        candidateCount: Int,
        isLoadingDirectory: Bool,
        directoryLoadError: String?,
        isSearchingNetwork: Bool,
        trimmedQuery: String
    ) -> Self {
        guard candidateCount == 0 else { return .people }
        if isLoadingDirectory { return .loading }
        if let directoryLoadError { return .loadFailed(message: directoryLoadError) }
        if isSearchingNetwork { return .awaitingSearch }
        return trimmedQuery.isEmpty ? .noPeople : .noMatches(query: trimmedQuery)
    }
}

import Foundation

/// Which body a recipient screen shows for the query it currently holds.
nonisolated enum RecipientQueryMode: Equatable {
    /// No query: quick actions above the known people.
    case browse
    /// Identifier-shaped: the resolver replaces the browse list, because a
    /// pasted or scanned reference already names one person.
    case resolve
    /// Free text: known people plus the relay search status.
    case search

    static func mode(isBlank: Bool, isIdentifierQuery: Bool) -> Self {
        // A blank query can never be identifier-shaped; deciding it here keeps
        // a stale resolution from outliving the text that produced it.
        if isBlank { return .browse }
        return isIdentifierQuery ? .resolve : .search
    }
}

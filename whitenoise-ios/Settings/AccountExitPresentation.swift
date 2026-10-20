nonisolated enum AccountExitIntent: Hashable {
    case signOut
    case deleteProfile
}

/// One root presenter owns sign-out, cleanup results, and the next profile choice.
nonisolated enum AccountExitPresentation: Equatable {
    case signOut
    case report
    case profileSelection

    static func resolve(
        intent: AccountExitIntent?,
        hasReport: Bool,
        needsProfileSelection: Bool,
        isExiting: Bool
    ) -> Self? {
        if hasReport { return .report }
        if intent == .signOut { return .signOut }
        if intent == nil, needsProfileSelection, !isExiting { return .profileSelection }
        return nil
    }
}

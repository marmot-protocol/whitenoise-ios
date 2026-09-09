import Foundation

/// Pure selection-mode helpers for the chat list, mirroring the Android
/// client's rules so bulk behavior matches across platforms. Kept free of
/// SwiftUI/state so the archive-toggle rule and selection reconciliation are
/// unit-testable.
nonisolated enum ChatListSelection {
    enum BulkArchiveAction {
        case archive
        case unarchive
    }

    /// Unarchive only when every selected chat is already archived; a mixed
    /// selection archives all. Matches the Android toggle rule.
    static func bulkArchiveAction(archivedFlags: [Bool]) -> BulkArchiveAction {
        if !archivedFlags.isEmpty, archivedFlags.allSatisfy({ $0 }) {
            return .unarchive
        }
        return .archive
    }

    /// Unmute only when every selected chat is already muted; a mixed
    /// selection mutes all.
    static func bulkMuteMutes(mutedFlags: [Bool]) -> Bool {
        !(!mutedFlags.isEmpty && mutedFlags.allSatisfy { $0 })
    }

    static func toggling(_ selected: Set<String>, id: String) -> Set<String> {
        if selected.contains(id) {
            return selected.subtracting([id])
        }
        return selected.union([id])
    }

    /// Drop selections that fell off the current visible (scope/search)
    /// list, so an action never touches a chat the user can't see.
    static func reconcile(_ selected: Set<String>, visibleIds: Set<String>) -> Set<String> {
        selected.intersection(visibleIds)
    }

    static func selectAll(_ visibleIds: [String]) -> Set<String> {
        Set(visibleIds)
    }

    /// Local deletion is only valid after membership is inactive. Keeping the
    /// bulk rule here prevents a mixed selection from exposing a destructive
    /// action that is invalid for some of its rows.
    static func canDeleteLocally(_ actions: [ChatDepartureAction?]) -> Bool {
        guard !actions.isEmpty else { return false }
        return actions.allSatisfy { $0 == .deleteLocally }
    }
}

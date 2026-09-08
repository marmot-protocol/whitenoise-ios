import Foundation
import Observation

/// Sole owner of chat-list search presentation.
///
/// Chats is the root of its navigation stack, so there is no route to pop and
/// no back button to fall back on. Every way out — the ✕ beside the field,
/// opening a result, a deep link, switching profiles — has to converge on
/// `exit()`, or the surface becomes unescapable.
///
/// One flag, deliberately: the search bar is app-drawn, so there is no system
/// presentation to mirror and nothing that can disagree with it.
@MainActor
@Observable
final class ChatListSearchPresentation {
    private(set) var isActive = false
    var query = ""

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isFiltering: Bool { !trimmedQuery.isEmpty }

    /// Repeated Search taps are a no-op rather than a re-mount, which would
    /// drop the query and the field's first responder.
    func activate() {
        guard !isActive else { return }
        isActive = true
    }

    /// Idempotent full cleanup. Removing the bar releases its focus, so the
    /// keyboard follows without a second flag to track it.
    func exit() {
        isActive = false
        query = ""
    }
}

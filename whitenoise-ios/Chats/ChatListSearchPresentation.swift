import Foundation
import Observation

/// Sole owner of chat-list search presentation.
///
/// Chats is the root of its navigation stack, so there is no route to pop and
/// no back button to fall back on. Every way out — the system's Cancel,
/// opening a result, a deep link, switching profiles — has to converge on
/// `exit()`, or the surface becomes unescapable.
@MainActor
@Observable
final class ChatListSearchPresentation {
    /// `searchable` is installed on demand so the field claims no row at rest.
    private(set) var isMounted = false
    /// Mirrors `searchable(isPresented:)`; the system writes `false` on Cancel.
    var isPresented = false
    var query = ""

    var isActive: Bool { isMounted || isPresented }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isFiltering: Bool { !trimmedQuery.isEmpty }

    /// Repeated Search taps are a no-op rather than a re-mount, which would
    /// drop the query and the field's first responder mid-animation.
    func activate() {
        guard !isMounted else { return }
        isMounted = true
    }

    /// Presenting is deferred to the mounted `searchable`: SwiftUI ignores a
    /// binding it was never handed, so activating in one update would leave
    /// the field installed but inert.
    func present() {
        guard isMounted, !isPresented else { return }
        isPresented = true
    }

    /// The one reconciliation point for the system's own dismissal — Cancel,
    /// or any interactive search dismissal the OS offers.
    func reconcileNativePresentation() {
        guard !isPresented else { return }
        exit()
    }

    /// Idempotent full cleanup: unmount, unpresent, drop the query.
    func exit() {
        isMounted = false
        isPresented = false
        query = ""
    }
}

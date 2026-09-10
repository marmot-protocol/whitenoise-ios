/// Terminal resolution of one interactive pop. `.ignored` covers a report that
/// belongs to an older gesture, or a second report for one that already
/// resolved, so dismissal and restoration each run exactly once per gesture.
nonisolated enum InteractivePopTransitionResolution: Equatable {
    case ignored
    case cancelled(restoresComposerFocus: Bool)
    case completed
}

/// Shared navigation epoch for a pushed screen that also owns row-level
/// gestures. Once an interactive pop begins the touch belongs to navigation,
/// so the screen's own gestures and any delayed composer-focus request must be
/// refused until the pop is cancelled. A completed pop stays navigating: the
/// screen is on its way out and must not revive input chrome behind the
/// transition.
nonisolated struct InteractivePopTransitionState: Equatable {
    private(set) var epoch = 0
    private(set) var isInteracting = false
    private(set) var didPop = false
    private(set) var composerWasFocused = false

    var isNavigating: Bool { isInteracting || didPop }

    /// Opens a new epoch and returns it, or nil when a pop is already
    /// interacting so the caller does not dismiss input chrome twice.
    mutating func begin(isComposerFocused: Bool) -> Int? {
        guard !isInteracting else { return nil }
        epoch &+= 1
        isInteracting = true
        didPop = false
        composerWasFocused = isComposerFocused
        return epoch
    }

    mutating func finish(epoch: Int, isCancelled: Bool) -> InteractivePopTransitionResolution {
        guard isInteracting, epoch == self.epoch else { return .ignored }
        isInteracting = false
        let wasFocused = composerWasFocused
        composerWasFocused = false
        guard isCancelled else {
            didPop = true
            return .completed
        }
        return .cancelled(restoresComposerFocus: wasFocused)
    }
}

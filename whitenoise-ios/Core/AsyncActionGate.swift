import Foundation

/// Serializes view-model mutations and lets reloads discard stale results.
@MainActor
struct AsyncActionGate {
    private(set) var isRunning = false
    private var generation = 0

    mutating func tryBegin() -> Bool {
        guard !isRunning else { return false }
        generation += 1
        isRunning = true
        return true
    }

    func reloadTicket() -> Int? {
        guard !isRunning else { return nil }
        return generation
    }

    func canApplyReload(startedAt ticket: Int) -> Bool {
        !isRunning && generation == ticket
    }

    mutating func end() {
        generation += 1
        isRunning = false
    }

    /// Rejects reloads that started before this call, without blocking actions.
    mutating func invalidateReloads() {
        generation += 1
    }
}

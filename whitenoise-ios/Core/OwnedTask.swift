import Foundation

/// A task slot that only its current owner can clear. A task that finishes
/// after a newer one took the slot leaves the newer task in place.
struct OwnedTask {
    private var id: UUID?
    private var task: Task<Void, Never>?

    var isActive: Bool { id != nil }

    func owns(_ id: UUID) -> Bool {
        self.id == id
    }

    /// Takes the slot for `task`, cancelling whichever task held it.
    mutating func install(_ id: UUID, _ task: Task<Void, Never>) {
        self.task?.cancel()
        self.id = id
        self.task = task
    }

    /// Clears the slot only if `id` still owns it.
    mutating func finish(_ id: UUID) {
        guard owns(id) else { return }
        self.id = nil
        task = nil
    }

    mutating func cancel() {
        task?.cancel()
        task = nil
        id = nil
    }
}

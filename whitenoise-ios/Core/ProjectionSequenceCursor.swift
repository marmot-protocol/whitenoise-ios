import Foundation

/// A generation is installed only when attaching a new native handle.
struct ProjectionSequenceCursor: Equatable {
    let generation: String
    private(set) var sequence: UInt64

    mutating func accept(generation: String, sequence: UInt64) -> Bool {
        guard generation == self.generation, sequence > self.sequence else { return false }
        self.sequence = sequence
        return true
    }
}

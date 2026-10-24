import UIKit

/// Thrown by `settleLayout` when the observed state keeps changing.
struct LayoutDidNotSettle: Error, CustomStringConvertible {
    let rounds: Int
    var description: String { "The observed UI state kept changing after \(rounds) drain rounds" }
}

/// Drains deferred UI work by ordering rather than time. A layout pass
/// flushes pending SwiftUI updates, whose `updateUIView` or geometry
/// callbacks may queue work on the main actor; yielding lets that work run,
/// and the next pass flushes whatever it changed. Returns once `quietRounds`
/// consecutive rounds leave `observe()` unchanged, and throws
/// `LayoutDidNotSettle` after `maxRounds`.
@MainActor
func settleLayout<State: Equatable>(
    _ view: UIView,
    quietRounds: Int = 3,
    maxRounds: Int = 100,
    observing observe: () -> State
) async throws {
    var previous = observe()
    var quiet = 0
    for _ in 0..<maxRounds {
        view.layoutIfNeeded()
        await Task.yield()
        view.layoutIfNeeded()
        let current = observe()
        quiet = current == previous ? quiet + 1 : 0
        if quiet == quietRounds { return }
        previous = current
    }
    throw LayoutDidNotSettle(rounds: maxRounds)
}

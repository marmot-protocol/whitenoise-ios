import MarmotKit

/// What the conversation does after MDK answers a failed send's Delete.
nonisolated enum DiscardFailedSendPlan: Equatable {
    /// Gone from this device: purge its decrypted media; the row leaves on its own.
    case discarded
    /// The group may still publish it, so nothing changed.
    case tryAgainLater
    /// Not a failed send (any more): fall back to a local-only delete.
    case hideLocally

    init(outcome: DiscardFailedSendOutcomeFfi) {
        switch outcome {
        case .discarded: self = .discarded
        case .stillSending: self = .tryAgainLater
        case .notFailedSend: self = .hideLocally
        }
    }
}

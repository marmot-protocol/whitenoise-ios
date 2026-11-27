import MarmotKit

nonisolated enum AccountDevicesActivationOutcome: Equatable, Sendable {
    case confirmed
    case pending

    init(disposition: SendAcceptDispositionFfi, activation: AccountDevicesActivationFfi?) {
        if disposition == .published || activation == .alreadyEnabled {
            self = .confirmed
        } else {
            self = .pending
        }
    }
}

import Foundation
import Observation

struct AccountExitError: Equatable {
    let title: String
    let message: String?
}

/// Keeps failures in the initiating sheet while the account operation stays unchanged.
@MainActor
@Observable
final class AccountExitFeedback {
    var error: AccountExitError?

    func receive(_ toast: Toast) {
        error = AccountExitError(title: toast.title, message: toast.message)
    }
}

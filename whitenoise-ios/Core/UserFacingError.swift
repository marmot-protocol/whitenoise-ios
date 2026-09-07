import Foundation
import MarmotKit

/// Separates the short, actionable error copy we show in the UI from the
/// diagnostic supplied by the runtime or an underlying framework.
struct UserFacingError: Equatable {
    let title: String
    let message: String
    let diagnostic: String

    static func toast(title: String, error: Error, fallbackMessage: String? = nil) -> Toast {
        let presentation = present(title: title, error: error, fallbackMessage: fallbackMessage)
        return Toast.error(
            presentation.title,
            message: presentation.message,
            diagnostic: presentation.diagnostic
        )
    }

    static func present(title: String, error: Error, fallbackMessage: String? = nil) -> UserFacingError {
        let diagnostic = sanitizedDiagnostic(for: error)
        if isDuplicateIdentity(error, diagnostic: diagnostic) {
            return UserFacingError(
                title: title,
                message: L10n.string("Identity already signed in on this device"),
                diagnostic: diagnostic
            )
        }
        if let setupMessage = accountSetupMessage(for: error) {
            return UserFacingError(
                title: title,
                message: setupMessage,
                diagnostic: diagnostic
            )
        }
        if let sendMessage = sendMessage(for: error) {
            return UserFacingError(
                title: title,
                message: sendMessage,
                diagnostic: diagnostic
            )
        }

        return UserFacingError(
            title: title,
            message: fallbackMessage ?? L10n.string("Retry"),
            diagnostic: diagnostic
        )
    }

    private static func isDuplicateIdentity(_ error: Error, diagnostic: String) -> Bool {
        if let marmotError = error as? MarmotKitError,
           case .DuplicateIdentity = marmotError {
            return true
        }

        // Older MarmotKit builds surfaced this condition only in runtime
        // details. Retain that match for imported diagnostics and mixed-version
        // development builds.
        return diagnostic.localizedCaseInsensitiveContains("account id is already in use")
    }

    private static func accountSetupMessage(for error: Error) -> String? {
        guard let marmotError = error as? MarmotKitError else { return nil }
        switch marmotError {
        case .AccountSetupRecoveryRequired:
            return L10n.string("Incomplete identity setup needs approval to recover.")
        case .AccountSetupRetryRequired, .AccountSetupKeyPackageRecoveryAvailable:
            return L10n.string("Identity setup can be resumed. Try importing again.")
        case .AccountSetupResetNotApplicable:
            return L10n.string("This incomplete identity setup could not be recovered.")
        default:
            return nil
        }
    }

    private static func sendMessage(for error: Error) -> String? {
        guard let marmotError = error as? MarmotKitError else { return nil }
        switch marmotError {
        case .GroupSendQueueFull:
            return L10n.string("This chat is still catching up. Wait for it to finish, then resend your message.")
        case .GroupUnrecoverableRepairRequired:
            return L10n.string("This conversation needs to be rejoined before you can send messages.")
        case .GroupRemoved:
            return L10n.string("You were removed from this group and can no longer send messages here.")
        case .OnboardingRequired:
            return L10n.string("Finish account setup before using this account.")
        case .OnboardingActionUnavailable:
            return L10n.string("Setup changed. Review the latest options and try again.")
        case .AccountWorkerBusy:
            return L10n.string("This account is still catching up. Try again in a moment.")
        case .AccountWorkerResponseTimedOut:
            return L10n.string("The operation may have completed. Refreshing the conversation is required before retrying.")
        default:
            return nil
        }
    }

    /// Runtime errors may include an nsec if input validation failed. Never
    /// make a secret copyable from a diagnostic surface.
    static func sanitizedDiagnostic(for error: Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        return raw
            .replacing(/nsec1[a-z0-9]+/.ignoresCase(), with: "nsec1…")
            .replacing(/[0-9a-fA-F]{64,}/, with: "…")
            .prefix(4_000)
            .description
    }
}

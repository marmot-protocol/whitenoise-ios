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
            diagnostic: presentation.diagnostic == presentation.message ? nil : presentation.diagnostic
        )
    }

    static func present(title: String, error: Error, fallbackMessage: String? = nil) -> UserFacingError {
        UserFacingError(
            title: capitalizingFirstLetter(title),
            message: message(for: error, fallbackMessage: fallbackMessage),
            diagnostic: sanitizedDiagnostic(for: error)
        )
    }

    nonisolated static func message(for error: Error, fallbackMessage: String? = nil) -> String {
        let error = underlyingError(error)
        let raw = rawMessage(for: error)
        if isDuplicateIdentity(error, diagnostic: raw ?? "") {
            return capitalizingFirstLetter(L10n.string("Identity already signed in on this device"))
        }
        if let marmotError = error as? MarmotKitError, case .FollowListUnavailable = marmotError {
            return L10n.string("Your follow list is unavailable from relays. Check your connection and relay settings, then try again. No follows were changed.")
        }
        if let setupMessage = accountSetupMessage(for: error) { return capitalizingFirstLetter(setupMessage) }
        if let sendMessage = sendMessage(for: error) { return capitalizingFirstLetter(sendMessage) }
        if let mediaMessage = mediaMessage(for: error) { return mediaMessage }
        let message = sanitizedText(fallbackMessage ?? raw ?? "")
        return message.isEmpty ? L10n.string("Please try again.") : message
    }

    private nonisolated static func underlyingError(_ error: Error) -> Error {
        if let failure = error as? RelaySettingsSaveFailure {
            return underlyingError(failure.underlyingError)
        }
        return error
    }

    /// UniFFI's LocalizedError conformance reflects the enum, not its message.
    private nonisolated static func rawMessage(for error: Error) -> String? {
        guard let error = error as? MarmotKitError else {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        switch error {
        case .Runtime(let details), .Publish(let details), .AccountCatchUp(let details),
             .InvalidChatPin(let details), .InvalidMessageDraft(let details),
             .InvalidMediaReference(let details), .InvalidHex(let details),
             .InvalidIdentity(let details), .InvalidKeyPackageEvent(let details),
             .StorageBusy(let details), .StorageClosed(let details),
             .SecretNotFound(let details), .KeystoreUnavailable(let details),
             .EncryptionFailed(let details), .Io(let details):
            return details
        case .MediaAttachmentRejected(_, let details), .MediaUnfetchable(let details),
             .MediaDownloadFailed(let details), .ChatWindowQuery(let details):
            return details
        default:
            return nil
        }
    }

    private nonisolated static func isDuplicateIdentity(_ error: Error, diagnostic: String) -> Bool {
        if let marmotError = error as? MarmotKitError,
           case .DuplicateIdentity = marmotError {
            return true
        }

        // Older MarmotKit builds surfaced this condition only in runtime
        // details. Retain that match for imported diagnostics and mixed-version
        // development builds.
        return diagnostic.localizedCaseInsensitiveContains("account id is already in use")
    }

    private nonisolated static func accountSetupMessage(for error: Error) -> String? {
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

    private nonisolated static func sendMessage(for error: Error) -> String? {
        guard let marmotError = error as? MarmotKitError else { return nil }
        switch marmotError {
        case .MissingKeyPackage:
            return L10n.string("This person has no compatible invitation key available. Ask them to open White Noise and try again.")
        case .UserBlocked:
            return L10n.string("Unblock this person before sending a message.")
        case .BlockListUnavailable:
            return L10n.string("The block list is unavailable. Please try again.")
        case .BlockPublicationUncertain:
            return L10n.string("The block-list update could not be confirmed. Retry the same change to check its status.")
        case .MessageDraftRevisionConflict:
            return L10n.string("The saved draft changed. Your text has been preserved.")
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

    private nonisolated static func mediaMessage(for error: Error) -> String? {
        guard let error = error as? MarmotKitError else { return nil }
        switch error {
        case .MediaAttachmentRejected(let kind, _):
            return kind == .unsupportedFormat
                ? L10n.string("Unsupported attachment")
                : L10n.string("Attachment couldn’t be read")
        case .AttachmentModeRequired:
            return L10n.string("Download settings need to be refreshed. Reopen the app and try again.")
        case .AttachmentAccountSignedOut:
            return L10n.string("Sign in to download attachments.")
        case .MediaUnfetchable:
            return L10n.string("No safe download location is available for this attachment.")
        case .MediaDownloadFailed:
            return L10n.string("Attachment download failed. Please try again.")
        default:
            return nil
        }
    }

    /// Runtime errors may include an nsec if input validation failed. Never
    /// make a secret copyable from a diagnostic surface.
    nonisolated static func sanitizedDiagnostic(for error: Error) -> String {
        let error = underlyingError(error)
        let diagnostic = sanitizedText(rawMessage(for: error) ?? "")
        return diagnostic.isEmpty ? message(for: error) : diagnostic
    }

    private nonisolated static func sanitizedText(_ raw: String) -> String {
        let text = raw
            .replacing(/nsec1[a-z0-9]+/.ignoresCase(), with: "nsec1…")
            .replacing(/[0-9a-fA-F]{64,}/, with: "…")
            .prefix(4_000)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return capitalizingFirstLetter(text)
    }

    private nonisolated static func capitalizingFirstLetter(_ text: String) -> String {
        guard let index = text.firstIndex(where: { $0.isLetter }) else { return text }
        return String(text[..<index]) + String(text[index]).uppercased() + text[text.index(after: index)...]
    }
}

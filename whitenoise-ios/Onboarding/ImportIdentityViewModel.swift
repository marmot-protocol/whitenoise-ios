import Foundation
import UIKit
import MarmotKit

/// Screen store for `ImportIdentityView`: owns the pasted-nsec field + in-flight
/// state and the import action. The secret-handling order is preserved verbatim
/// — consume/clear the visible field before the first await, and clear the
/// sensitive clipboard in a `defer` so it runs on every outcome (#nsec hygiene).
/// The clipboard token is NOT captured at import tap: it is set by the view's
/// paste interception (`PasteAwareNsecTextArea.onPaste`) at a genuine user paste,
/// then tied to the post-paste field value so later edits cannot turn a stale
/// paste token into permission to wipe unrelated clipboard contents. If the user
/// typed/autofilled the field, pasted a non-nsec, edited the pasted value into a
/// different nsec, or pasted then copied unrelated content, the deferred clear
/// is a no-op (#409). The clear never reads `pasteboard.string` (which would
/// raise the iOS paste-disclosure banner). The tested validation statics
/// (isPlausibleNsec /
/// consumeIdentityForImport) stay on the view; this calls them. `AppState` and
/// `dismiss` are passed in.
@MainActor
@Observable
final class ImportIdentityViewModel {
    var identity = ""
    var isImporting = false
    var showIncompleteSetupRecoveryConfirmation = false

    @ObservationIgnored
    private var recoveryConfirmationContinuation: CheckedContinuation<Bool, Never>?

    /// Set by the view's paste interception at a genuine user paste; nil when
    /// the nsec was typed/autofilled or never pasted. Gates the deferred clear.
    var pastedClipboardToken: SensitiveClipboard.Token?
    private var pastedClipboardIdentity: String?

    func runImport(using appState: AppState, dismiss: () -> Void) async {
        // Take the in-flight guard synchronously before consuming/clearing the
        // visible secret and before the first await so a fast double-tap can't
        // start two concurrent imports — the second would otherwise consume an
        // already-cleared field — while SwiftUI's `.disabled(!canSubmit)` render
        // still lags the tap (#439).
        guard ImportIdentityView.isPlausibleNsec(identity),
              beginImportIfIdle()
        else { return }
        let trimmed = ImportIdentityView.consumeIdentityForImport(&identity)
        let clipboardToken = consumeClipboardTokenForImportedIdentity(trimmed)
        defer {
            SensitiveClipboard.clear(matching: clipboardToken)
            clearPastedClipboardToken()
            isImporting = false
        }
        do {
            do {
                try await appState.importIdentity(trimmed)
                if appState.pendingAccountSetup != nil { return }
            } catch {
                guard Self.requiresIncompleteSetupRecovery(error) else { throw error }
                Haptics.error()
                guard await requestIncompleteSetupRecoveryConfirmation() else { return }
                try await appState.recoverIncompleteIdentity(trimmed)
            }
            Haptics.success()
            appState.present(.success(L10n.string("Welcome back"), message: L10n.string("Identity imported.")))
            dismiss()
        } catch {
            try? await appState.refreshAccounts(refreshUnreadSummaries: false)
            presentImportFailure(error, using: appState)
        }
    }

    static func requiresIncompleteSetupRecovery(_ error: Error) -> Bool {
        guard let marmotError = error as? MarmotKitError else { return false }
        if case .AccountSetupRecoveryRequired = marmotError { return true }
        return false
    }

    func requestIncompleteSetupRecoveryConfirmation() async -> Bool {
        guard recoveryConfirmationContinuation == nil else { return false }
        return await withCheckedContinuation { continuation in
            recoveryConfirmationContinuation = continuation
            showIncompleteSetupRecoveryConfirmation = true
        }
    }

    func resolveIncompleteSetupRecoveryConfirmation(approved: Bool) {
        let continuation = recoveryConfirmationContinuation
        recoveryConfirmationContinuation = nil
        showIncompleteSetupRecoveryConfirmation = false
        continuation?.resume(returning: approved)
    }

    private func presentImportFailure(_ error: Error, using appState: AppState) {
        Haptics.error()
        let presentation = UserFacingError.present(
            title: L10n.string("Import failed"),
            error: error,
            fallbackMessage: Self.importFallbackMessage(for: error)
        )
        appState.present(.error(
            presentation.title,
            message: presentation.message,
            diagnostic: presentation.diagnostic
        ))
    }

    static func importFallbackMessage(for error: Error) -> String {
        if let marmotError = error as? MarmotKitError {
            switch marmotError {
            case .InvalidIdentity:
                return L10n.string("That private key isn't valid. Check it and try again.")
            case .Publish:
                return L10n.string("Identity setup can be resumed. Try importing again.")
            default:
                break
            }
        }
        return L10n.string("Retry")
    }

    /// Synchronous in-flight gate for `runImport`. Returns `true` and marks the
    /// import in-flight only when idle; a re-entrant call returns `false` without
    /// touching the visible secret. Extracted so the double-tap guard is testable
    /// without standing up an `AppState`/Marmot runtime (#439).
    func beginImportIfIdle() -> Bool {
        guard !isImporting else { return false }
        isImporting = true
        return true
    }

    func recordPastedClipboardToken(_ token: SensitiveClipboard.Token?, resultingIdentity: String) {
        guard let token else {
            clearPastedClipboardToken()
            return
        }
        guard let normalized = NostrProfileReference.normalizedNsec(resultingIdentity) else {
            clearPastedClipboardToken()
            return
        }
        pastedClipboardToken = token
        pastedClipboardIdentity = normalized
    }

    func clipboardTokenForImportedIdentity(_ importedIdentity: String) -> SensitiveClipboard.Token? {
        guard let normalized = NostrProfileReference.normalizedNsec(importedIdentity) else {
            return nil
        }
        guard normalized == pastedClipboardIdentity else { return nil }
        return pastedClipboardToken
    }

    func consumeClipboardTokenForImportedIdentity(_ importedIdentity: String) -> SensitiveClipboard.Token? {
        defer { clearPastedClipboardToken() }
        return clipboardTokenForImportedIdentity(importedIdentity)
    }

    func clearPastedClipboardToken() {
        pastedClipboardToken = nil
        pastedClipboardIdentity = nil
    }

    /// Dismiss-without-import teardown: scrub the visible field, wipe the
    /// matching pasteboard generation (the same token gate `runImport`'s defer
    /// uses, so unrelated clipboard content is never touched), and drop the
    /// shadow copy — every exit from the sheet clears the secret.
    func scrubDismissedImportState(pasteboard: UIPasteboard = .general) {
        resolveIncompleteSetupRecoveryConfirmation(approved: false)
        identity = ""
        SensitiveClipboard.clear(matching: pastedClipboardToken, from: pasteboard)
        clearPastedClipboardToken()
    }
}

import Foundation

/// Screen store for `ImportIdentityView`: owns the pasted-nsec field + in-flight
/// state and the import action. The secret-handling order is preserved verbatim
/// — consume/clear the visible field before the first await, and clear the
/// sensitive clipboard in a `defer` so it runs on every outcome (#nsec hygiene).
/// The clipboard token is NOT captured at import tap: it is set by the view's
/// paste interception (`PasteAwareNsecField.onPaste`) at a genuine user paste,
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
    var error: String?

    /// Set by the view's paste interception at a genuine user paste; nil when
    /// the nsec was typed/autofilled or never pasted. Gates the deferred clear.
    var pastedClipboardToken: SensitiveClipboard.Token?
    private var pastedClipboardIdentity: String?

    func runImport(using appState: AppState, dismiss: () -> Void) async {
        let trimmed = ImportIdentityView.consumeIdentityForImport(&identity)
        let clipboardToken = clipboardTokenForImportedIdentity(trimmed)
        isImporting = true
        error = nil
        defer {
            SensitiveClipboard.clear(matching: clipboardToken)
            clearPastedClipboardToken()
            isImporting = false
        }
        do {
            try await appState.importIdentity(trimmed)
            Haptics.success()
            appState.present(.success(L10n.string("Welcome back"), message: L10n.string("Identity imported.")))
            dismiss()
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
            appState.present(.error(L10n.string("Import failed"), message: error.localizedDescription))
        }
    }

    func recordPastedClipboardToken(_ token: SensitiveClipboard.Token, resultingIdentity: String) {
        let normalized = resultingIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ImportIdentityView.isPlausibleNsec(normalized) else {
            clearPastedClipboardToken()
            return
        }
        pastedClipboardToken = token
        pastedClipboardIdentity = normalized
    }

    func clipboardTokenForImportedIdentity(_ importedIdentity: String) -> SensitiveClipboard.Token? {
        let normalized = importedIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized == pastedClipboardIdentity else { return nil }
        return pastedClipboardToken
    }

    func clearPastedClipboardToken() {
        pastedClipboardToken = nil
        pastedClipboardIdentity = nil
    }
}

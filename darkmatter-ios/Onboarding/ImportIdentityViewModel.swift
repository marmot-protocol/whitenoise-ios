import Foundation

/// Screen store for `ImportIdentityView`: owns the pasted-nsec field + in-flight
/// state and the import action. The secret-handling order is preserved verbatim
/// — consume/clear the visible field before the first await, and clear the
/// sensitive clipboard in a `defer` so it runs on every outcome (#nsec hygiene).
/// The clipboard token is NOT captured at import tap: it is set by the view's
/// paste interception (`PasteAwareNsecField.onPaste`) at a genuine user paste,
/// the only signal that proves the clipboard still holds the pasted secret. If
/// the user typed/autofilled the field, or pasted then copied unrelated
/// content, the token is nil/stale and the deferred clear is a no-op so we
/// never wipe their newer/unrelated clipboard contents (#409). The clear never
/// reads `pasteboard.string` (which would raise the iOS paste-disclosure
/// banner). The tested validation statics (isPlausibleNsec /
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

    func runImport(using appState: AppState, dismiss: () -> Void) async {
        let clipboardToken = pastedClipboardToken
        let trimmed = ImportIdentityView.consumeIdentityForImport(&identity)
        isImporting = true
        error = nil
        defer {
            SensitiveClipboard.clear(matching: clipboardToken)
            pastedClipboardToken = nil
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
}

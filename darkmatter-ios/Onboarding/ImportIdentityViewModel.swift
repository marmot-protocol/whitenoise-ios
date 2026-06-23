import Foundation

/// Screen store for `ImportIdentityView`: owns the pasted-nsec field + in-flight
/// state and the import action. The secret-handling order is preserved verbatim
/// — consume/clear the visible field before the first await, and clear the
/// sensitive clipboard in a `defer` so it runs on every outcome (#nsec hygiene).
/// The tested validation statics (isPlausibleNsec / consumeIdentityForImport)
/// stay on the view; this calls them. `AppState` and `dismiss` are passed in.
@MainActor
@Observable
final class ImportIdentityViewModel {
    var identity = ""
    var isImporting = false
    var error: String?

    func runImport(using appState: AppState, dismiss: () -> Void) async {
        let trimmed = ImportIdentityView.consumeIdentityForImport(&identity)
        isImporting = true
        error = nil
        defer {
            SensitiveClipboard.clear(trimmed)
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

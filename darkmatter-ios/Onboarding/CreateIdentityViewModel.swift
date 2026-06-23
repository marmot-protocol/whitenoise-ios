import Foundation

/// Screen store for `CreateIdentityView`: owns the in-flight/error state and the
/// generate-identity action, so the view is pure rendering. `AppState` and the
/// view's `dismiss` are passed in rather than retained.
@MainActor
@Observable
final class CreateIdentityViewModel {
    var isCreating = false
    var error: String?

    func runCreate(using appState: AppState, dismiss: () -> Void) async {
        isCreating = true
        error = nil
        do {
            try await appState.createIdentity()
            Haptics.success()
            // Parent handles navigation (sheet dismiss / onboarding advance).
            dismiss()
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
            appState.present(.error(L10n.string("Identity creation failed"), message: error.localizedDescription))
        }
        isCreating = false
    }
}

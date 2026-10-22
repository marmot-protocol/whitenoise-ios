import Foundation

/// Screen store for `IdentityView`: owns the confirmation/sheet presentation
/// flags and the nsec export flow (raw + encrypted), so the view is pure
/// rendering. Identity reads (display name, npub, active account) stay on the
/// AppState forwarders. Methods take `AppState` rather than retaining it.
@MainActor
@Observable
final class IdentityViewModel {
    // Avoid the isolated-deinit task-local crash on older Swift runtimes (including iOS 26.2).
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {}

    var showRawExportConfirm = false
    var showEncryptedExportSheet = false
    var exportShareText: String?
    var exportInFlight = false
    var exportError: String?

    func exportRawNsec(using appState: AppState) async {
        guard !exportInFlight else { return }
        guard let accountRef = appState.activeAccountRef else { return }
        exportInFlight = true
        exportError = nil
        defer { exportInFlight = false }

        do {
            let nsec = try await appState.revealNsec(accountRef: accountRef)
            exportShareText = nsec
            Haptics.success()
        } catch {
            Haptics.error()
            exportError = IdentityKeyExportPresentation.errorMessage(for: error)
        }
    }

    func exportEncryptedNsec(passphrase: String, using appState: AppState) async {
        guard !exportInFlight else { return }
        guard let accountRef = appState.activeAccountRef else { return }
        exportInFlight = true
        exportError = nil
        defer { exportInFlight = false }

        do {
            let ncryptsec = try await appState.exportEncryptedSecretKey(
                accountRef: accountRef,
                passphrase: passphrase
            )
            showEncryptedExportSheet = false
            exportShareText = ncryptsec
            Haptics.success()
        } catch {
            Haptics.error()
            exportError = IdentityKeyExportPresentation.errorMessage(for: error)
        }
    }
}

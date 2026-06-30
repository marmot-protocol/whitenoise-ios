import Foundation
import MarmotKit

/// Screen store for `ProfileEditView`: owns the editable kind:0 fields + the
/// load/publish flow, so the view is pure rendering. The validation *logic*
/// stays in the pure `ProfileEditMetadataDraft` (defined alongside the view and
/// tested directly); this exposes the live draft plus the per-field presentation
/// messages. The view keeps `saveDisabled` because it also reads
/// `appState.activeAccountRef`. `AppState` is passed into the load/publish
/// methods rather than retained.
@MainActor
@Observable
final class ProfileEditViewModel {
    var existingName: String?
    var displayName = ""
    var about = ""
    var nip05 = ""
    // Not user-editable here; preserved so a kind:0 republish keeps them.
    var existingPicture: String?
    var existingLud16: String?

    var isPublishing = false
    var error: String?

    private(set) var loadedAccountIdHex: String?

    var currentDraft: ProfileEditMetadataDraft {
        ProfileEditMetadataDraft(
            name: existingName,
            displayName: displayName,
            about: about,
            nip05: nip05,
            preservedPicture: existingPicture,
            preservedLud16: existingLud16
        )
    }

    var invalidNip05Message: String? { validationMessage(for: .nip05) }

    func validationMessage(for field: ProfileEditMetadataField) -> String? {
        guard currentDraft.validationError == field else { return nil }
        switch field {
        case .nip05:
            return L10n.string("Enter a valid NIP-05 address like name@example.com.")
        }
    }

    func loadExisting(using appState: AppState) async {
        guard let id = appState.activeAccount?.accountIdHex else { return }
        let cachedProfile = appState.profile(forAccountIdHex: id)
        let loadedProfile = await appState.reloadProfileProjection(forAccountIdHex: id)?.profile
        // The reload is async; if the active account changed under us, drop the
        // result rather than seed this editor with another account's metadata.
        guard appState.activeAccount?.accountIdHex == id else { return }
        guard let profile = loadedProfile ?? cachedProfile else { return }
        let isNewAccount = loadedAccountIdHex != id
        let formFields = ProfileEditFormFields(profile: profile)
        existingName = formFields.name
        // Carry picture and lud16 forward as-is so saving never wipes them.
        existingPicture = formFields.picture.isEmpty ? nil : formFields.picture
        existingLud16 = formFields.lud16.isEmpty ? nil : formFields.lud16
        displayName = ProfileEditFieldSeeding.seeded(
            current: displayName, loaded: formFields.displayName, isNewAccount: isNewAccount
        )
        about = ProfileEditFieldSeeding.seeded(
            current: about, loaded: formFields.about, isNewAccount: isNewAccount
        )
        nip05 = ProfileEditFieldSeeding.seeded(
            current: nip05, loaded: formFields.nip05, isNewAccount: isNewAccount
        )
        loadedAccountIdHex = id
    }

    func publish(using appState: AppState) async {
        guard !isPublishing else { return }
        guard let accountRef = appState.activeAccountRef,
              let accountIdHex = appState.activeAccount?.accountIdHex,
              // Never republish fields loaded for a now-inactive account.
              loadedAccountIdHex == accountIdHex
        else { return }

        let draft = currentDraft
        if let validationError = draft.validationError {
            Haptics.error()
            error = validationMessage(for: validationError)
            return
        }
        guard let normalizedMetadata = draft.normalizedMetadata else { return }

        isPublishing = true
        defer { isPublishing = false }
        error = nil

        do {
            let client = try appState.currentMarmotClient()
            let relays = await appState.relayPublishRelays(for: accountRef)
            let bootstrapRelays = await appState.relayBootstrapRelays(for: accountRef)
            _ = try await client.publishUserProfile(
                accountRef: accountRef,
                profile: normalizedMetadata.ffi,
                defaultRelays: relays,
                bootstrapRelays: bootstrapRelays
            )
            await appState.reloadProfileProjection(forAccountIdHex: accountIdHex)
            Haptics.success()
            appState.present(.success(
                L10n.string("Profile published"),
                message: L10n.plural("Your kind:0 metadata is live on %lld relays.", Int64(relays.count))
            ))
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
            appState.present(.error(L10n.string("Couldn't publish profile"), message: error.localizedDescription))
        }
    }
}

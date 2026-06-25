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
    var picture = ""
    var nip05 = ""
    var lud16 = ""

    var isPublishing = false
    var error: String?

    var currentDraft: ProfileEditMetadataDraft {
        ProfileEditMetadataDraft(
            name: existingName,
            displayName: displayName,
            about: about,
            picture: picture,
            nip05: nip05,
            lud16: lud16
        )
    }

    var invalidPictureMessage: String? { validationMessage(for: .picture) }
    var invalidNip05Message: String? { validationMessage(for: .nip05) }
    var invalidLud16Message: String? { validationMessage(for: .lud16) }

    func validationMessage(for field: ProfileEditMetadataField) -> String? {
        guard currentDraft.validationError == field else { return nil }
        switch field {
        case .picture:
            return L10n.string("Only public HTTPS image URLs are allowed.")
        case .nip05:
            return L10n.string("Enter a valid NIP-05 address like name@example.com.")
        case .lud16:
            return L10n.string("Enter a valid Lightning address like name@example.com.")
        }
    }

    func loadExisting(using appState: AppState) async {
        guard let id = appState.activeAccount?.accountIdHex else { return }
        let cachedProfile = appState.profile(forAccountIdHex: id)
        let loadedProfile = await appState.reloadProfileProjection(forAccountIdHex: id)?.profile
        guard let profile = loadedProfile ?? cachedProfile else { return }
        let formFields = ProfileEditFormFields(profile: profile)
        existingName = formFields.name
        // Only seed empty fields so we don't clobber in-progress edits.
        if displayName.isEmpty { displayName = formFields.displayName }
        if about.isEmpty { about = formFields.about }
        if picture.isEmpty { picture = formFields.picture }
        if nip05.isEmpty { nip05 = formFields.nip05 }
        if lud16.isEmpty { lud16 = formFields.lud16 }
    }

    func publish(using appState: AppState) async {
        guard !isPublishing else { return }
        guard let accountRef = appState.activeAccountRef,
              let accountIdHex = appState.activeAccount?.accountIdHex
        else { return }

        let draft = currentDraft
        if let validationError = draft.validationError {
            Haptics.error()
            error = validationMessage(for: validationError)
            return
        }
        guard let normalizedMetadata = draft.normalizedMetadata else { return }

        isPublishing = true
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
        isPublishing = false
    }
}

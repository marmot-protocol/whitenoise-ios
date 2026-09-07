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
    var displayName = ""
    var about = ""
    var picture = ""
    var nip05 = ""
    // Not user-editable here; preserved so a kind:0 republish keeps them.
    var existingBanner: String?
    var existingLud16: String?

    var isPublishing = false
    var isUploadingPicture = false
    var error: String?

    private(set) var loadedAccountIdHex: String?
    // The reset detector must see every attempt: a failed load never moves
    // the Save gate above, so gating alone would treat a return to the
    // previously loaded account as "same account" and let another account's
    // typed draft survive into a publishable state.
    private var lastAttemptedAccountIdHex: String?
    // Tickets order overlapping loads. The throwing read runs detached and
    // can outlive SwiftUI task cancellation, so an account-only completion
    // guard would let a stale A read re-authorize Save during a newer A load
    // after an A→B→A cycle.
    private(set) var loadTicket = 0

    var currentDraft: ProfileEditMetadataDraft {
        ProfileEditMetadataDraft(
            displayName: displayName,
            about: about,
            picture: picture,
            nip05: nip05,
            preservedBanner: existingBanner,
            preservedLud16: existingLud16
        )
    }

    var invalidPictureMessage: String? { validationMessage(for: .picture) }
    var invalidNip05Message: String? { validationMessage(for: .nip05) }

    func validationMessage(for field: ProfileEditMetadataField) -> String? {
        guard currentDraft.validationError == field else { return nil }
        switch field {
        case .picture:
            return L10n.string("Only public HTTPS image URLs are allowed.")
        case .nip05:
            return L10n.string("Enter a valid NIP-05 address like name@example.com.")
        }
    }

    func loadExisting(using appState: AppState) async {
        guard let id = appState.activeAccount?.accountIdHex else { return }
        let ticket = beginLoadAttempt(accountIdHex: id)
        // The projection batch erases read errors (`try?`), so the editor
        // takes its authority from the throwing read: nil is definitive
        // absence, a throw is unknown state that must gate publishing. The
        // display cache gets no vote — it can trail the relays.
        var loadedProfile: UserProfileMetadataFfi?
        var readFailed = false
        do {
            loadedProfile = try await appState.currentMarmotClient()
                .userProfileForEditing(accountIdHex: id)
        } catch {
            readFailed = true
        }
        // The read is async; if the active account changed under us, drop the
        // result rather than seed this editor with another account's metadata.
        // (The ticket check in `applyLoadOutcome` separately drops results
        // whose load window has been superseded.)
        guard appState.activeAccount?.accountIdHex == id else { return }
        applyLoadOutcome(
            ProfileEditLoadResolution.resolve(
                hasLoadedProfile: loadedProfile != nil,
                readFailed: readFailed
            ),
            accountIdHex: id,
            profile: loadedProfile,
            ticket: ticket
        )
    }

    /// Marks the start of a load window: revokes publishing authorization,
    /// records the attempt, and — on an account change — resets every
    /// editable field immediately, BEFORE any await. Recording at completion
    /// instead would let a discarded mid-switch load leave another account's
    /// typed draft behind as an apparent same-account edit.
    @discardableResult
    func beginLoadAttempt(accountIdHex id: String) -> Int {
        loadTicket += 1
        // Publishing authorization is revoked for the whole load window and
        // re-granted only by a successful outcome — a failed or in-flight
        // load must never leave Save armed with a previous account's grant.
        loadedAccountIdHex = nil
        let isDifferentAccount = ProfileEditLoadSeeding.isDifferentLoadedAccount(
            previousAccountId: lastAttemptedAccountIdHex,
            loading: id
        )
        lastAttemptedAccountIdHex = id
        if isDifferentAccount {
            existingBanner = nil
            existingLud16 = nil
            displayName = ""
            about = ""
            picture = ""
            nip05 = ""
            error = nil
        }
        return loadTicket
    }

    /// Split from `loadExisting` so the field state machine is testable
    /// without an `AppState`. Outcomes carry the ticket of the load window
    /// that produced them; anything superseded is dropped whole.
    func applyLoadOutcome(
        _ resolution: ProfileEditLoadResolution,
        accountIdHex id: String,
        profile: UserProfileMetadataFfi?,
        ticket: Int
    ) {
        guard ticket == loadTicket else { return }
        switch resolution {
        case .loadFailed:
            loadedAccountIdHex = nil
            error = L10n.string("Couldn't load your profile. Close and reopen this screen to retry.")
        case .enableFirstPublish:
            existingBanner = nil
            existingLud16 = nil
            // A same-account retry after a failed read keeps the form (no
            // account change), so the stale failure message must clear here —
            // Save arming under a visible load error reads as a broken screen.
            error = nil
            loadedAccountIdHex = id
        case .seedExisting:
            guard let profile else { return }
            error = nil
            let formFields = ProfileEditFormFields(profile: profile)
            existingBanner = formFields.banner.isEmpty ? nil : formFields.banner
            existingLud16 = formFields.lud16.isEmpty ? nil : formFields.lud16
            // Cross-account resets already happened when the window opened,
            // so seeding only has the same-account case left: typed input
            // wins over loaded values.
            displayName = ProfileEditFieldSeeding.seeded(
                current: displayName, loaded: formFields.displayName, isNewAccount: false
            )
            about = ProfileEditFieldSeeding.seeded(
                current: about, loaded: formFields.about, isNewAccount: false
            )
            picture = ProfileEditFieldSeeding.seeded(
                current: picture, loaded: formFields.picture, isNewAccount: false
            )
            nip05 = ProfileEditFieldSeeding.seeded(
                current: nip05, loaded: formFields.nip05, isNewAccount: false
            )
            loadedAccountIdHex = id
        }
    }

    /// Uploads the selected public profile image without encryption. Publishing
    /// the returned URL remains part of the explicit Save profile action.
    func updatePicture(
        with draft: GroupImageUploadDraft?,
        using appState: AppState
    ) async throws {
        guard !isUploadingPicture, !isPublishing else {
            throw ProfileImageUploadError.unavailable
        }
        guard let accountRef = appState.activeAccountRef,
              let accountIdHex = appState.activeAccount?.accountIdHex,
              loadedAccountIdHex == accountIdHex
        else {
            throw ProfileImageUploadError.unavailable
        }

        guard let draft else {
            picture = ""
            return
        }

        isUploadingPicture = true
        defer { isUploadingPicture = false }
        let client = try appState.currentMarmotClient()
        let uploadedURL = try await client.uploadProfileImage(
            accountRef: accountRef,
            data: draft.data,
            mediaType: draft.mediaType,
            blossomServer: nil
        )
        guard let normalizedURL = ContentSanitizer.imageURL(uploadedURL)?.absoluteString else {
            throw ProfileImageUploadError.invalidReturnedURL
        }
        picture = normalizedURL
    }

    func publish(using appState: AppState) async {
        guard !isPublishing else { return }
        guard let accountRef = appState.activeAccountRef,
              let accountIdHex = appState.activeAccount?.accountIdHex,
              // Never republish fields loaded for a now-inactive account.
              loadedAccountIdHex == accountIdHex
        else { return }

        let draft = currentDraft
        if draft.validationError != nil {
            Haptics.error()
            return
        }
        guard let normalizedMetadata = draft.normalizedMetadata else { return }

        isPublishing = true
        defer { isPublishing = false }
        error = nil

        do {
            let client = try appState.currentMarmotClient()
            _ = try await client.publishUserProfileUsingAccountRelays(
                accountRef: accountRef,
                profile: normalizedMetadata.ffi
            )
            await appState.reloadProfileProjection(forAccountIdHex: accountIdHex)
            Haptics.success()
            appState.present(.success(
                L10n.string("Profile published"),
                message: L10n.string("Your kind:0 metadata is live on your account relays.")
            ))
        } catch {
            Haptics.error()
            appState.present(UserFacingError.toast(title: L10n.string("Couldn't publish profile"), error: error))
        }
    }
}

nonisolated enum ProfileImageUploadError: LocalizedError {
    case invalidReturnedURL
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidReturnedURL:
            L10n.string("The image server returned an invalid URL.")
        case .unavailable:
            L10n.string("Profile image upload is not available right now.")
        }
    }
}

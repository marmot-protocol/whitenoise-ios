import SwiftUI
import MarmotKit

/// Edit the Nostr kind:0 profile for the currently active account. Marmot
/// chooses the account relay lists; iOS only supplies the edited metadata.
struct ProfileEditView: View {
    @Environment(AppState.self) private var appState
    @State private var model = ProfileEditViewModel()
    @State private var photoMenuAction: WNPhotoMenuAction?
    @State private var photoError: String?
    @State private var photoUploadFailure: PhotoUploadFailure?

    private struct PhotoUploadFailure {
        let draft: GroupImageUploadDraft
        let accountID: String?
        let ticket: Int
    }
    @State private var isPhotoUploadPending = false
    @State private var isEditing = false
    @State private var editSnapshot: ProfileEditDraftSnapshot?
    @State private var isReloading = false

    var body: some View {
        @Bindable var model = model
        return ProfileEditForm(
            displayName: $model.displayName,
            nip05: $model.nip05,
            about: $model.about,
            isEditing: isEditing,
            isLoading: isReloading || (model.loadedAccountIdHex == nil && model.error == nil),
            isPublishing: model.isPublishing,
            hasLoadError: model.error != nil,
            saveError: $model.saveError,
            addressError: model.invalidNip05Message,
            saveDisabled: saveDisabled,
            onReload: reloadProfile,
            onRetrySave: saveProfile
        ) {
            avatarSection
        }
        .productScreen(.settings, section: .account)
        .localizedNavigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isEditing)
        .toolbar {
            ProfileEditToolbar(
                isEditing: isEditing,
                isPublishing: model.isPublishing,
                cancelDisabled: model.isPublishing || model.isUploadingPicture || isPhotoUploadPending,
                saveDisabled: saveDisabled,
                editDisabled: model.loadedAccountIdHex == nil,
                onCancel: cancelEditing,
                onSave: saveProfile,
                onEdit: beginEditing
            )
        }
        .wnPhotoSourceMenu(
            selection: $photoMenuAction,
            confirmsPublicUpload: true,
            prepareDraft: { data, fileName, sourceURL in
                let accountID = appState.activeAccount?.accountIdHex
                let ticket = model.loadTicket
                let draft = try await ProfileImageDraftProcessor.prepare(
                    data: data,
                    fileName: fileName,
                    typeIdentifier: AvatarImageCropper.outputTypeIdentifier,
                    sourceURL: sourceURL
                )
                guard isCurrent(ticket: ticket, accountID: accountID) else { throw CancellationError() }
                return draft
            },
            onRemove: { applyUpload(nil) },
            onSelect: { selection in
                applyUpload(selection)
            }
        )
        .profilePhotoUploadFailureAlert($photoUploadFailure) { failure in
            guard isEditing, isCurrent(ticket: failure.ticket, accountID: failure.accountID) else { return }
            applyUpload(failure.draft)
        }
        .alert(L10n.string("Couldn’t upload photo"), isPresented: Binding(
            get: { photoError != nil },
            set: { if !$0 { photoError = nil } }
        )) {
            Button("Close", role: .cancel) {}
        } message: {
            Text(photoError ?? "")
        }
        .task(id: appState.activeAccount?.accountIdHex) {
            isEditing = false
            editSnapshot = nil
            photoError = nil
            photoUploadFailure = nil
            await model.loadExisting(using: appState)
        }
    }

    @ViewBuilder
    private var avatarSection: some View {
        if let active = appState.activeAccount {
            WNProfilePhotoSection(
                hasPhoto: !model.picture.isEmpty,
                selection: $photoMenuAction,
                isEditing: isEditing,
                isBusy: model.isUploadingPicture || isPhotoUploadPending,
                isDisabled: model.isPublishing || model.loadedAccountIdHex != active.accountIdHex,
                error: model.invalidPictureMessage
            ) {
                avatarPreview(accountIdHex: active.accountIdHex)
            }
        }
    }

    private func avatarPreview(accountIdHex: String) -> some View {
        WNAvatarPreview(
            name: model.displayName.isEmpty
                ? appState.shortNpub(forAccountIdHex: accountIdHex)
                : model.displayName,
            pictureURL: ContentSanitizer.imageURL(model.picture)
        )
    }

    private func saveProfile() {
        Task {
            guard let savingAccountID = appState.activeAccount?.accountIdHex else { return }
            if await model.publish(using: appState),
               appState.activeAccount?.accountIdHex == savingAccountID {
                isEditing = false
                editSnapshot = nil
            }
        }
    }

    private func beginEditing() {
        editSnapshot = ProfileEditDraftSnapshot(model: model)
        isEditing = true
    }

    private func cancelEditing() {
        editSnapshot?.restore(model, activeAccountID: appState.activeAccount?.accountIdHex)
        model.saveError = nil
        editSnapshot = nil
        photoError = nil
        photoUploadFailure = nil
        isEditing = false
    }

    private func reloadProfile() {
        guard !isReloading else { return }
        isReloading = true
        Task {
            defer { isReloading = false }
            await model.loadExisting(using: appState)
        }
    }

    private func applyUpload(_ draft: GroupImageUploadDraft?) {
        let accountID = appState.activeAccount?.accountIdHex
        let ticket = model.loadTicket
        photoError = nil
        photoUploadFailure = nil
        isPhotoUploadPending = draft != nil
        Task {
            guard isCurrent(ticket: ticket, accountID: accountID) else {
                isPhotoUploadPending = false
                return
            }
            await save(draft)
        }
    }

    private func save(_ draft: GroupImageUploadDraft?) async {
        let accountID = appState.activeAccount?.accountIdHex
        let ticket = model.loadTicket
        defer { isPhotoUploadPending = false }
        do {
            try await model.updatePicture(with: draft, using: appState)
            Haptics.selection()
        } catch {
            guard !(error is CancellationError), isCurrent(ticket: ticket, accountID: accountID) else { return }
            // Match sign-up for upload failures, including an unusable returned URL.
            // An unavailable operation has no meaningful Retry until its guards change.
            if let draft, (error as? ProfileImageUploadError) != .unavailable {
                photoUploadFailure = PhotoUploadFailure(draft: draft, accountID: accountID, ticket: ticket)
            } else {
                photoError = UserFacingError.message(for: error)
            }
            Haptics.error()
        }
    }

    private func isCurrent(ticket: Int, accountID: String?) -> Bool {
        !Task.isCancelled && model.loadTicket == ticket && appState.activeAccount?.accountIdHex == accountID
    }

    /// Stays in the view because it also reads `appState.activeAccountRef`; the
    /// draft validation it consults lives on the model's `currentDraft`.
    private var saveDisabled: Bool {
        model.isPublishing
            || model.isUploadingPicture
            || isPhotoUploadPending
            || appState.activeAccountRef == nil
            || model.loadedAccountIdHex != appState.activeAccount?.accountIdHex
            || ContentSanitizer.displayName(model.displayName) == nil
            || model.currentDraft.validationError != nil
    }
}

/// What `loadExisting` should do when the profile lookup settles: seed the
/// form, unlock a first publish (fresh identity, definitively no kind:0), or
/// stay gated because the read itself threw and publishing could replace
/// existing metadata with blanks. The distinction rides on the throwing
/// `userProfile` read — a nil return is authoritative absence, a throw is
/// unknown state.
nonisolated enum ProfileEditLoadResolution: Equatable {
    case seedExisting
    case enableFirstPublish
    case loadFailed

    static func resolve(
        hasLoadedProfile: Bool,
        readFailed: Bool
    ) -> ProfileEditLoadResolution {
        // The throwing read is the only authority. A failure gates
        // publishing outright, and a successful nil is definitive absence —
        // the display cache gets no vote in either direction, because a
        // stale projection could otherwise unlock a republish of old fields.
        if readFailed { return .loadFailed }
        return hasLoadedProfile ? .seedExisting : .enableFirstPublish
    }
}

nonisolated enum ProfileEditLoadSeeding {
    static func isDifferentLoadedAccount(previousAccountId: String?, loading accountId: String) -> Bool {
        guard let previousAccountId else { return false }
        return previousAccountId != accountId
    }
}

nonisolated enum ProfileEditFieldSeeding {
    /// On a switch to a different account, adopt that account's value; otherwise
    /// only fill an empty field so in-progress edits survive a same-account reload.
    static func seeded(current: String, loaded: String, isNewAccount: Bool) -> String {
        if isNewAccount || current.isEmpty { return loaded }
        return current
    }
}

nonisolated struct ProfileEditFormFields: Equatable {
    var displayName: String
    var about: String
    var picture: String
    var banner: String
    var nip05: String
    var lud16: String

    init(profile: UserProfileMetadataFfi) {
        displayName = ContentSanitizer.displayName(profile.displayName)
            ?? ContentSanitizer.displayName(profile.name)
            ?? ""
        about = profile.about ?? ""
        picture = profile.picture ?? ""
        banner = profile.banner ?? ""
        nip05 = profile.nip05 ?? ""
        lud16 = profile.lud16 ?? ""
    }
}

nonisolated enum ProfileEditMetadataField: Equatable {
    case picture
    case nip05
}

nonisolated struct ProfileEditMetadataDraft: Equatable {
    var displayName: String
    var about: String
    var picture: String
    var nip05: String
    // Neither the banner nor lud16 is editable on this screen. Both are carried
    // forward verbatim from the existing profile so publishing a kind:0
    // replacement never blanks them, and an existing value the sanitizer would
    // reject cannot gate a Save the form gives no way to fix.
    var preservedBanner: String?
    var preservedLud16: String?

    init(
        displayName: String,
        about: String,
        picture: String,
        nip05: String,
        preservedBanner: String? = nil,
        preservedLud16: String?
    ) {
        self.displayName = displayName
        self.about = about
        self.picture = picture
        self.nip05 = nip05
        self.preservedBanner = preservedBanner
        self.preservedLud16 = preservedLud16
    }

    var validationError: ProfileEditMetadataField? {
        if !trimmedPicture.isEmpty, normalizedPictureURL == nil {
            return .picture
        }
        if !trimmedNip05.isEmpty, normalizedNip05 == nil {
            return .nip05
        }
        return nil
    }

    var normalizedMetadata: ProfileEditMetadata? {
        guard validationError == nil else { return nil }
        let normalizedName = ContentSanitizer.displayName(displayName)
        return ProfileEditMetadata(
            // One visible Name field must not leave a stale alternate name.
            name: normalizedName,
            displayName: normalizedName,
            about: ContentSanitizer.multilineText(about),
            picture: normalizedPictureURL,
            banner: preservedBanner,
            nip05: normalizedNip05,
            lud16: preservedLud16
        )
    }

    private var trimmedPicture: String {
        picture.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNip05: String {
        nip05.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedPictureURL: String? {
        guard !trimmedPicture.isEmpty else { return nil }
        return ContentSanitizer.imageURL(trimmedPicture)?.absoluteString
    }

    private var normalizedNip05: String? {
        ContentSanitizer.profileAddress(trimmedNip05)
    }
}

nonisolated struct ProfileEditMetadata: Equatable {
    var name: String?
    var displayName: String?
    var about: String?
    var picture: String?
    var banner: String?
    var nip05: String?
    var lud16: String?

    var ffi: UserProfileMetadataFfi {
        UserProfileMetadataFfi(
            name: name,
            displayName: displayName,
            about: about,
            picture: picture,
            banner: banner,
            nip05: nip05,
            lud16: lud16
        )
    }
}

import SwiftUI
import MarmotKit
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// Edit the Nostr kind:0 profile for the currently active account. Marmot
/// chooses the account relay lists; iOS only supplies the edited metadata.
struct ProfileEditView: View {
    private enum PendingPhotoSource {
        case photos
        case files
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var model = ProfileEditViewModel()
    @State private var pendingPhotoSource: PendingPhotoSource?
    @State private var showAvatarDisclosure = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showWebImagePicker = false
    @State private var cropSource: AvatarImageCropSource?
    @State private var photoError: String?
    @State private var photoProgressPhase: ProfileImageProgressPhase?
    @State private var isEditing = false
    @State private var editSnapshot: ProfileEditDraftSnapshot?
    @FocusState private var nameFocused: Bool
    @FocusState private var nip05Focused: Bool
    @FocusState private var aboutFocused: Bool

    var body: some View {
        @Bindable var model = model
        return Form {
            avatarSection

            Section {
                if isEditing {
                    WNInput(
                        placeholder: L10n.string("Name"),
                        text: $model.displayName,
                        submitLabel: .next,
                        autocapitalization: .words,
                        disablesAutocorrection: false,
                        focus: $nameFocused,
                        onSubmit: { nip05Focused = true }
                    )
                    .textContentType(.name)
                    .wnInputRow()
                } else {
                    WNFieldValue(value: model.displayName, placeholder: L10n.string("Not set"))
                        .wnInputRow()
                }
            } header: {
                Text("Name").wnSectionHeader()
            }

            Section {
                if isEditing {
                    WNInput(
                        placeholder: L10n.string("Verified Nostr Address"),
                        text: $model.nip05,
                        submitLabel: .next,
                        focus: $nip05Focused,
                        onSubmit: { aboutFocused = true }
                    )
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .wnInputRow()
                } else {
                    WNFieldValue(value: model.nip05, placeholder: L10n.string("Not set"))
                        .wnInputRow()
                }
            } header: {
                Text("Verified Nostr Address").wnSectionHeader()
            } footer: {
                if isEditing && model.invalidNip05Message != nil {
                    Text("Enter an address like name@example.com.")
                }
            }

            Section {
                if isEditing {
                    WNInput(
                        placeholder: L10n.string("A little about you"),
                        text: $model.about,
                        kind: .multiline(3 ... 6),
                        autocapitalization: .sentences,
                        disablesAutocorrection: false,
                        focus: $aboutFocused
                    )
                    .accessibilityLabel("About")
                    .wnInputRow()
                } else {
                    WNFieldValue(
                        value: model.about,
                        placeholder: L10n.string("A little about you"),
                        kind: .multiline(3 ... 6)
                    )
                    .accessibilityLabel("About")
                    .wnInputRow()
                }
            } header: {
                Text("About").wnSectionHeader()
            }

            if model.error != nil {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Couldn't load this screen", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Button("Retry") {
                            Task { await model.loadExisting(using: appState) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .productScreen(.settings, section: .account)
        .localizedNavigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if isEditing {
                    WNButton(
                        title: "Cancel",
                        emphasis: .secondary,
                        size: .compact,
                        action: cancelEditing
                    )
                    .disabled(model.isPublishing || model.isUploadingPicture)
                } else {
                    WNIconButton(title: "Back", systemImage: "chevron.backward") {
                        dismiss()
                    }
                }
            }

            ToolbarItem(placement: .primaryAction) {
                if isEditing {
                    WNButton(
                        title: model.isPublishing ? "Publishing…" : "Done",
                        size: .compact,
                        isLoading: model.isPublishing
                    ) {
                        clearFocus()
                        Task {
                            await model.publish(using: appState)
                            if model.error == nil {
                                isEditing = false
                                editSnapshot = nil
                            }
                        }
                    }
                    .disabled(saveDisabled)
                } else {
                    WNButton(title: "Edit", emphasis: .secondary, size: .compact, action: beginEditing)
                        .disabled(model.loadedAccountIdHex == nil)
                }
            }
        }
        .task(id: appState.activeAccount?.accountIdHex) { await model.loadExisting(using: appState) }
        .alert("Your avatar is public", isPresented: $showAvatarDisclosure) {
            Button("Continue") {
                switch pendingPhotoSource {
                case .photos:
                    showPhotoPicker = true
                case .files:
                    showFileImporter = true
                case nil:
                    break
                }
                pendingPhotoSource = nil
            }
            Button("Cancel", role: .cancel) {
                pendingPhotoSource = nil
            }
        } message: {
            Text("The photo is uploaded to a public service, and removing it from your profile may not delete the uploaded copy.")
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPickerView(
                selectionLimit: 1,
                filter: .images,
                onSelection: { selections in
                    guard let selection = selections.first else { return }
                    photoError = nil
                    cropSource = AvatarImageCropSource(
                        data: selection.data,
                        fileName: selection.fileName,
                        typeIdentifier: selection.typeIdentifier,
                        sourceURL: nil
                    )
                },
                onError: { photoError = $0.localizedDescription },
                onDismiss: { showPhotoPicker = false }
            )
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            prepareImportedFile(result)
        }
        .sheet(isPresented: $showWebImagePicker) {
            OnboardingAvatarWebImagePicker { url in
                prepareWebImage(url)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $cropSource) { source in
            AvatarImageCropEditor(source: source) { source, croppedData in
                upload(
                    data: croppedData,
                    fileName: source.fileName,
                    typeIdentifier: "public.jpeg",
                    sourceURL: source.sourceURL
                )
            }
        }
        .background(.background)
    }

    @ViewBuilder
    private var avatarSection: some View {
        if let active = appState.activeAccount {
            Section {
                VStack(spacing: 0) {
                    WNAvatarPreview(
                        name: model.displayName.isEmpty
                            ? appState.shortNpub(forAccountIdHex: active.accountIdHex)
                            : model.displayName,
                        pictureURL: ContentSanitizer.imageURL(model.picture)
                    )
                    .containerRelativeFrame(.horizontal, count: 3, span: 1, spacing: 0)

                    if isEditing {
                        avatarMenu(loadedAccountIdHex: active.accountIdHex)
                            .padding(.top)

                        if let photoProgressPhase {
                            ProgressView(photoProgressPhase.label)
                                .font(.footnote)
                                .padding(.top)
                        }

                        if let photoError {
                            Text(photoError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .padding(.top)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func avatarMenu(loadedAccountIdHex: String) -> some View {
        Menu {
            Button {
                requestPhotoSource(.photos)
            } label: {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
            }

            Button {
                requestPhotoSource(.files)
            } label: {
                Label("Choose from Files", systemImage: "folder")
            }

            Button {
                showWebImagePicker = true
            } label: {
                Label("Find Image on Web", systemImage: "globe")
            }

            if !model.picture.isEmpty {
                Divider()
                Button("Remove Photo", systemImage: "trash", role: .destructive) {
                    applyUpload(nil)
                }
            }
        } label: {
            Text(model.picture.isEmpty ? "Add Photo" : "Change Photo")
        }
        .wnAvatarActionButtonStyle()
        .disabled(
            model.isPublishing
                || model.isUploadingPicture
                || photoProgressPhase != nil
                || model.loadedAccountIdHex != loadedAccountIdHex
        )
    }

    private func beginEditing() {
        editSnapshot = ProfileEditDraftSnapshot(model: model)
        isEditing = true
    }

    private func cancelEditing() {
        clearFocus()
        editSnapshot?.restore(model)
        model.error = nil
        editSnapshot = nil
        photoError = nil
        isEditing = false
    }

    private func clearFocus() {
        nameFocused = false
        nip05Focused = false
        aboutFocused = false
    }

    private func requestPhotoSource(_ source: PendingPhotoSource) {
        pendingPhotoSource = source
        showAvatarDisclosure = true
    }

    private func prepareImportedFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            photoError = nil
            Task { await loadImportedFile(url) }
        case .failure(let error):
            photoError = error.localizedDescription
        }
    }

    private func loadImportedFile(_ url: URL) async {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try AvatarImageCropper.boundedFileData(from: url)
            }.value
            cropSource = AvatarImageCropSource(
                data: data,
                fileName: url.lastPathComponent,
                typeIdentifier: nil,
                sourceURL: url
            )
        } catch {
            photoError = error.localizedDescription
        }
    }

    private func prepareWebImage(_ url: URL) {
        photoError = nil
        Task {
            do {
                let data = try await RemoteImageFetch.imageData(for: url)
                cropSource = AvatarImageCropSource(
                    data: data,
                    fileName: url.lastPathComponent,
                    typeIdentifier: nil,
                    sourceURL: url
                )
            } catch {
                photoError = error.localizedDescription
            }
        }
    }

    /// Unlike Sign Up, which holds the avatar until the account exists, an edit
    /// has an account to upload against now: the public URL is fetched here and
    /// only the kind:0 republish waits for Done.
    private func upload(
        data: Data,
        fileName: String?,
        typeIdentifier: String?,
        sourceURL: URL?
    ) {
        photoError = nil
        photoProgressPhase = .preparing
        Task {
            do {
                let draft = try await GroupImageDraftProcessor.prepare(
                    data: data,
                    fileName: fileName,
                    typeIdentifier: typeIdentifier,
                    sourceURL: sourceURL
                )
                photoProgressPhase = .uploading
                await save(draft)
            } catch {
                photoProgressPhase = nil
                photoError = error.localizedDescription
                Haptics.error()
            }
        }
    }

    private func applyUpload(_ draft: GroupImageUploadDraft?) {
        photoError = nil
        Task { await save(draft) }
    }

    private func save(_ draft: GroupImageUploadDraft?) async {
        defer { photoProgressPhase = nil }
        do {
            try await model.updatePicture(with: draft, using: appState)
            Haptics.selection()
        } catch {
            photoError = error.localizedDescription
            Haptics.error()
        }
    }

    /// Stays in the view because it also reads `appState.activeAccountRef`; the
    /// draft validation it consults lives on the model's `currentDraft`.
    private var saveDisabled: Bool {
        model.isPublishing
            || model.isUploadingPicture
            || photoProgressPhase != nil
            || appState.activeAccountRef == nil
            || model.loadedAccountIdHex != appState.activeAccount?.accountIdHex
            || ContentSanitizer.displayName(model.displayName) == nil
            || model.currentDraft.validationError != nil
    }
}

private struct ProfileEditDraftSnapshot {
    let displayName: String
    let about: String
    let picture: String
    let nip05: String

    init(model: ProfileEditViewModel) {
        displayName = model.displayName
        about = model.about
        picture = model.picture
        nip05 = model.nip05
    }

    func restore(_ model: ProfileEditViewModel) {
        model.displayName = displayName
        model.about = about
        model.picture = picture
        model.nip05 = nip05
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

enum ProfileImageProgressPhase: Equatable {
    case preparing
    case uploading

    var label: String {
        switch self {
        case .preparing:
            L10n.string("Preparing image…")
        case .uploading:
            L10n.string("Uploading profile image…")
        }
    }
}

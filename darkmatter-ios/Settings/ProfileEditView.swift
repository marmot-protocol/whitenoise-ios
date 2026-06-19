import SwiftUI
import MarmotKit

/// Edit the Nostr kind:0 profile for the currently active account. Marmot
/// chooses the account relay lists; iOS only supplies the edited metadata.
struct ProfileEditView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var existingName: String?
    @State private var displayName: String = ""
    @State private var about: String = ""
    @State private var picture: String = ""
    @State private var nip05: String = ""
    @State private var lud16: String = ""

    @State private var isPublishing = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                if let active = appState.activeAccount {
                    HStack(spacing: 12) {
                        AvatarBubble(
                            seed: active.accountIdHex,
                            title: displayName.isEmpty
                                ? appState.shortNpub(forAccountIdHex: active.accountIdHex)
                                : displayName,
                            pictureURL: ProfileSanitizer.imageURL(picture)
                        )
                        .frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName.isEmpty ? L10n.string("Anonymous") : displayName)
                                .font(.headline)
                            Text(appState.shortNpub(forAccountIdHex: active.accountIdHex))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Profile") {
                TextField("Display name", text: $displayName)
                TextField("About", text: $about, axis: .vertical)
                    .lineLimit(2...5)
                TextField("Picture URL", text: $picture)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                if let invalidPictureMessage {
                    Label(invalidPictureMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                TextField("NIP-05 (name@domain)", text: $nip05)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let invalidNip05Message {
                    Label(invalidNip05Message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                TextField("Lightning (lud16)", text: $lud16)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let invalidLud16Message {
                    Label(invalidLud16Message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await publish() }
                } label: {
                    HStack {
                        if isPublishing {
                            ProgressView().controlSize(.small)
                        }
                        Text(isPublishing ? L10n.string("Publishing…") : L10n.string("Save profile"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(saveDisabled)
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadExisting() }
    }

    private var trimmedPicture: String {
        picture.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentDraft: ProfileEditMetadataDraft {
        ProfileEditMetadataDraft(
            name: existingName,
            displayName: displayName,
            about: about,
            picture: picture,
            nip05: nip05,
            lud16: lud16
        )
    }

    private var normalizedPictureURL: String? {
        ProfileSanitizer.imageURL(trimmedPicture)?.absoluteString
    }

    private var saveDisabled: Bool {
        isPublishing
            || appState.activeAccountRef == nil
            || currentDraft.validationError != nil
    }

    private var invalidPictureMessage: String? {
        validationMessage(for: .picture)
    }

    private var invalidNip05Message: String? {
        validationMessage(for: .nip05)
    }

    private var invalidLud16Message: String? {
        validationMessage(for: .lud16)
    }

    private func validationMessage(for field: ProfileEditMetadataField) -> String? {
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

    @MainActor
    private func loadExisting() async {
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

    @MainActor
    private func publish() async {
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
            let relays = await appState.relayPublishRelays(for: accountRef)
            let bootstrapRelays = await appState.relayBootstrapRelays(for: accountRef)
            _ = try await appState.marmot.publishUserProfile(
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

nonisolated struct ProfileEditFormFields: Equatable {
    var name: String?
    var displayName: String
    var about: String
    var picture: String
    var nip05: String
    var lud16: String

    init(profile: UserProfileMetadataFfi) {
        name = profile.name
        displayName = profile.displayName ?? ""
        about = profile.about ?? ""
        picture = profile.picture ?? ""
        nip05 = profile.nip05 ?? ""
        lud16 = profile.lud16 ?? ""
    }
}

nonisolated enum ProfileEditMetadataField: Equatable {
    case picture
    case nip05
    case lud16
}

nonisolated struct ProfileEditMetadataDraft: Equatable {
    var name: String?
    var displayName: String
    var about: String
    var picture: String
    var nip05: String
    var lud16: String

    var validationError: ProfileEditMetadataField? {
        if !trimmedPicture.isEmpty, normalizedPictureURL == nil {
            return .picture
        }
        if !trimmedNip05.isEmpty, normalizedNip05 == nil {
            return .nip05
        }
        if !trimmedLud16.isEmpty, normalizedLud16 == nil {
            return .lud16
        }
        return nil
    }

    var normalizedMetadata: ProfileEditMetadata? {
        guard validationError == nil else { return nil }
        let name = ProfileSanitizer.displayName(self.name)
        let displayName = ProfileSanitizer.displayName(self.displayName)
        return ProfileEditMetadata(
            name: name,
            displayName: displayName,
            about: ProfileSanitizer.multilineText(about),
            picture: normalizedPictureURL,
            nip05: normalizedNip05,
            lud16: normalizedLud16
        )
    }

    private var trimmedPicture: String {
        picture.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNip05: String {
        nip05.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedLud16: String {
        lud16.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedPictureURL: String? {
        ProfileSanitizer.imageURL(trimmedPicture)?.absoluteString
    }

    private var normalizedNip05: String? {
        ProfileSanitizer.profileAddress(trimmedNip05)
    }

    private var normalizedLud16: String? {
        ProfileSanitizer.profileAddress(trimmedLud16)
    }
}

nonisolated struct ProfileEditMetadata: Equatable {
    var name: String?
    var displayName: String?
    var about: String?
    var picture: String?
    var nip05: String?
    var lud16: String?

    var ffi: UserProfileMetadataFfi {
        UserProfileMetadataFfi(
            name: name,
            displayName: displayName,
            about: about,
            picture: picture,
            nip05: nip05,
            lud16: lud16
        )
    }
}

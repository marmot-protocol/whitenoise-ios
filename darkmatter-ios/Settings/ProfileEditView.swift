import SwiftUI
import MarmotKit

/// Edit the Nostr kind:0 profile for the currently active account. Marmot
/// chooses the account relay lists; iOS only supplies the edited metadata.
struct ProfileEditView: View {
    @Environment(AppState.self) private var appState
    @State private var model = ProfileEditViewModel()

    var body: some View {
        @Bindable var model = model
        return Form {
            Section {
                if let active = appState.activeAccount {
                    HStack(spacing: 12) {
                        AvatarBubble(
                            seed: active.accountIdHex,
                            title: model.displayName.isEmpty
                                ? appState.shortNpub(forAccountIdHex: active.accountIdHex)
                                : model.displayName,
                            pictureURL: ProfileSanitizer.imageURL(model.picture)
                        )
                        .frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName.isEmpty ? L10n.string("Anonymous") : model.displayName)
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
                TextField("Display name", text: $model.displayName)
                TextField("About", text: $model.about, axis: .vertical)
                    .lineLimit(2...5)
                TextField("Picture URL", text: $model.picture)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                if let invalidPictureMessage = model.invalidPictureMessage {
                    Label(invalidPictureMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                TextField("NIP-05 (name@domain)", text: $model.nip05)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let invalidNip05Message = model.invalidNip05Message {
                    Label(invalidNip05Message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                TextField("Lightning (lud16)", text: $model.lud16)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let invalidLud16Message = model.invalidLud16Message {
                    Label(invalidLud16Message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await model.publish(using: appState) }
                } label: {
                    HStack {
                        if model.isPublishing {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.isPublishing ? L10n.string("Publishing…") : L10n.string("Save profile"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(saveDisabled)
            }

            if let error = model.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadExisting(using: appState) }
    }

    /// Stays in the view because it also reads `appState.activeAccountRef`; the
    /// draft validation it consults lives on the model's `currentDraft`.
    private var saveDisabled: Bool {
        model.isPublishing
            || appState.activeAccountRef == nil
            || model.currentDraft.validationError != nil
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

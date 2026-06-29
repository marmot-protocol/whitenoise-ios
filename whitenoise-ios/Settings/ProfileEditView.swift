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
                    AvatarBubble(
                        seed: active.accountIdHex,
                        title: model.displayName.isEmpty
                            ? appState.shortNpub(forAccountIdHex: active.accountIdHex)
                            : model.displayName,
                        pictureURL: ProfileSanitizer.imageURL(model.existingPicture)
                    )
                    .frame(width: 72, height: 72)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }

            Section("Profile") {
                TextField("Display name", text: $model.displayName)
                TextField("About", text: $model.about, axis: .vertical)
                    .lineLimit(2...5)
                TextField("NIP-05 (name@domain)", text: $model.nip05)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let invalidNip05Message = model.invalidNip05Message {
                    Label(invalidNip05Message, systemImage: "exclamationmark.triangle.fill")
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
                .buttonBorderShape(.roundedRectangle(radius: 12))
                .controlSize(.large)
                .disabled(saveDisabled)
                .listRowBackground(Color.clear)
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
        .task(id: appState.activeAccount?.accountIdHex) { await model.loadExisting(using: appState) }
    }

    /// Stays in the view because it also reads `appState.activeAccountRef`; the
    /// draft validation it consults lives on the model's `currentDraft`.
    private var saveDisabled: Bool {
        model.isPublishing
            || appState.activeAccountRef == nil
            || model.currentDraft.validationError != nil
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
    case nip05
}

nonisolated struct ProfileEditMetadataDraft: Equatable {
    var name: String?
    var displayName: String
    var about: String
    var nip05: String
    // Picture and lud16 are not editable on this screen. They are carried
    // forward verbatim from the existing profile so publishing a kind:0
    // replacement never blanks values the user already has set.
    var preservedPicture: String?
    var preservedLud16: String?

    var validationError: ProfileEditMetadataField? {
        if !trimmedNip05.isEmpty, normalizedNip05 == nil {
            return .nip05
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
            picture: preservedPicture,
            nip05: normalizedNip05,
            lud16: preservedLud16
        )
    }

    private var trimmedNip05: String {
        nip05.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedNip05: String? {
        ProfileSanitizer.profileAddress(trimmedNip05)
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

import SwiftUI
import MarmotKit

/// Edit the Nostr kind:0 profile for the currently active account. Marmot
/// chooses the account relay lists; iOS only supplies the edited metadata.
struct ProfileEditView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String = ""
    @State private var about: String = ""
    @State private var picture: String = ""
    @State private var nip05: String = ""
    @State private var lud16: String = ""

    @State private var isPublishing = false
    @State private var error: String?
    @State private var success = false

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
                TextField("NIP-05 (name@domain)", text: $nip05)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Lightning (lud16)", text: $lud16)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
                .disabled(isPublishing || appState.activeAccountRef == nil)
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

    @MainActor
    private func loadExisting() async {
        guard let id = appState.activeAccount?.accountIdHex else { return }
        guard let profile = appState.profile(forAccountIdHex: id) else { return }
        // Only seed empty fields so we don't clobber in-progress edits.
        if displayName.isEmpty { displayName = profile.displayName ?? profile.name ?? "" }
        if about.isEmpty { about = profile.about ?? "" }
        if picture.isEmpty { picture = profile.picture ?? "" }
        if nip05.isEmpty { nip05 = profile.nip05 ?? "" }
        if lud16.isEmpty { lud16 = profile.lud16 ?? "" }
    }

    @MainActor
    private func publish() async {
        guard let accountRef = appState.activeAccountRef else { return }
        isPublishing = true
        error = nil
        success = false

        let metadata = UserProfileMetadataFfi(
            name: displayName.isEmpty ? nil : displayName,
            displayName: displayName.isEmpty ? nil : displayName,
            about: about.isEmpty ? nil : about,
            picture: picture.isEmpty ? nil : picture,
            nip05: nip05.isEmpty ? nil : nip05,
            lud16: lud16.isEmpty ? nil : lud16
        )

        do {
            let relays = appState.relayPublishRelays(for: accountRef)
            let bootstrapRelays = appState.relayBootstrapRelays(for: accountRef)
            let published = try await appState.marmot.publishUserProfile(
                accountRef: accountRef,
                profile: metadata,
                defaultRelays: relays,
                bootstrapRelays: bootstrapRelays
            )
            if let id = appState.activeAccount?.accountIdHex {
                appState.cacheProfile(published, for: id)
            }
            success = true
            Haptics.success()
            appState.present(.success(
                L10n.string("Profile published"),
                message: L10n.formatted("Your kind:0 metadata is live on %lld relays.", Int64(relays.count))
            ))
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
            appState.present(.error(L10n.string("Couldn't publish profile"), message: error.localizedDescription))
        }
        isPublishing = false
    }
}

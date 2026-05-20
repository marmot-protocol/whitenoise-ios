import SwiftUI
import MarmotKit

/// Edit the Nostr kind:0 profile for the currently active account. Writes
/// directly to the configured relays via marmot-app.
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
                                ? IdentityFormatter.short(active.accountIdHex)
                                : displayName
                        )
                        .frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName.isEmpty ? "Anonymous" : displayName)
                                .font(.headline)
                            Text(IdentityFormatter.short(active.accountIdHex))
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
                        Text(isPublishing ? "Publishing…" : "Publish to Relays")
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

            if success {
                Section {
                    Label("Profile published", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
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
            _ = try await appState.marmot.publishUserProfile(
                accountRef: accountRef,
                profile: metadata,
                defaultRelays: appState.defaultRelays,
                bootstrapRelays: appState.defaultRelays
            )
            success = true
        } catch {
            self.error = error.localizedDescription
        }
        isPublishing = false
    }
}

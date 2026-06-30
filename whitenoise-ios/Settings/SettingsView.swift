import SwiftUI
import MarmotKit

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showQR = false
    @State private var showProfileEdit = false
    @State private var showAccounts = false
    @State private var showSignOutConfirm = false

    var body: some View {
        Form {
            Section("Profile") {
                if let active = appState.activeAccount {
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            Button {
                                showProfileEdit = true
                            } label: {
                                HStack(spacing: 12) {
                                    AvatarBubble(
                                        seed: active.accountIdHex,
                                        title: appState.displayName(forAccountIdHex: active.accountIdHex),
                                        pictureURL: appState.avatarURL(forAccountIdHex: active.accountIdHex)
                                    )
                                    .frame(width: 44, height: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(appState.displayName(forAccountIdHex: active.accountIdHex))
                                            .font(.headline)
                                        Text(appState.shortNpub(forAccountIdHex: active.accountIdHex))
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)

                            Button {
                                showQR = true
                            } label: {
                                Image(systemName: "qrcode")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("My QR code")

                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }

                        Button {
                            showAccounts = true
                        } label: {
                            HStack(spacing: 6) {
                                Text("Switch Profile")
                                Image(systemName: "arrow.up.arrow.down")
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                    .padding(.vertical, 2)
                }

                NavigationLink {
                    ProfileEditView()
                } label: {
                    Label("Edit Profile", systemImage: "person.crop.circle")
                }

                NavigationLink {
                    IdentityView()
                } label: {
                    Label("Profile keys", systemImage: "key.fill")
                }

                NavigationLink {
                    RelaysView()
                } label: {
                    Label("Relays", systemImage: "antenna.radiowaves.left.and.right")
                }

                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    Label("Appearance", systemImage: "paintbrush.fill")
                }

                NavigationLink {
                    NotificationSettingsView()
                } label: {
                    Label("Notifications", systemImage: "bell.badge.fill")
                }

                NavigationLink {
                    KeyPackagesView()
                } label: {
                    Label("Key Packages", systemImage: "key.icloud.fill")
                }

                NavigationLink {
                    PrivacySecuritySettingsView()
                } label: {
                    Label("Privacy & Security", systemImage: "hand.raised.fill")
                }
            }

            Section("About") {
                LabeledContent("Version") {
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Built on") {
                    Text(L10n.formatted("MarmotKit %@", marmotVersion))
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(role: .destructive) {
                    showSignOutConfirm = true
                } label: {
                    Label {
                        Text("Sign out of this profile")
                    } icon: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(.red)
                    }
                }
                .tint(.red)
                .disabled(appState.activeAccount == nil)
            } footer: {
                Text("Signing out removes this profile and its local key material from this device.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Settings")
        .navigationDestination(isPresented: $showProfileEdit) {
            ProfileEditView()
        }
        .navigationDestination(isPresented: $showAccounts) {
            AccountsView()
        }
        .sheet(isPresented: $showQR) {
            if let hex = appState.activeAccount?.accountIdHex {
                ProfileQRView(accountIdHex: hex)
            }
        }
        .fullScreenCover(isPresented: $showSignOutConfirm) {
            FullScreenConfirmationDialog(
                title: L10n.string("Sign out?"),
                message: L10n.string("Signing out removes this profile and its local key material from this device."),
                systemImage: "rectangle.portrait.and.arrow.right",
                destructiveTitle: L10n.string("Sign out"),
                onConfirm: {
                    showSignOutConfirm = false
                    Task { await appState.signOut() }
                },
                onCancel: { showSignOutConfirm = false }
            )
            .appAppearance()
        }
    }

    private var appVersion: String {
        let dict = Bundle.main.infoDictionary
        let version = dict?["CFBundleShortVersionString"] as? String ?? "—"
        let build = dict?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var marmotVersion: String {
        // Compile-time constant regenerated by sync-bindings.sh; always
        // present (the MARMOT_VERSION text file isn't bundled into the app).
        let tag = MarmotKitVersion.darkmatterTag
        if tag.isEmpty {
            return MarmotKitVersion.darkmatterSHA
        }
        return "\(tag) (\(MarmotKitVersion.darkmatterSHA))"
    }
}

import SwiftUI
import MarmotKit

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showDiagnostics = false

    var body: some View {
        Form {
            Section("Account") {
                if let active = appState.activeAccount {
                    NavigationLink {
                        ProfileEditView()
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
                        }
                        .padding(.vertical, 2)
                    }
                }

                NavigationLink {
                    AccountsView()
                } label: {
                    Label("Accounts", systemImage: "person.2.circle.fill")
                }

                NavigationLink {
                    IdentityView()
                } label: {
                    Label("Identity & Keys", systemImage: "key.fill")
                }
            }

            Section("Network") {
                NavigationLink {
                    RelaysView()
                } label: {
                    Label("Relays", systemImage: "antenna.radiowaves.left.and.right")
                }
            }

            Section("About") {
                LabeledContent("Version") {
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Built on") {
                    Text("MarmotKit \(marmotVersion)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Toggle("Show diagnostics", isOn: $showDiagnostics)
            }

            if showDiagnostics {
                Section("Diagnostics") {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Open Diagnostics", systemImage: "stethoscope")
                    }
                }
            }
        }
        .navigationTitle("Settings")
    }

    private var appVersion: String {
        let dict = Bundle.main.infoDictionary
        let version = dict?["CFBundleShortVersionString"] as? String ?? "—"
        let build = dict?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var marmotVersion: String {
        // Read MARMOT_VERSION from the bundle's vendored package if present.
        // Falls back to "—" in dev configurations where it isn't bundled.
        if let url = Bundle.main.url(forResource: "MARMOT_VERSION", withExtension: nil),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            let firstLine = text.split(separator: "\n").first ?? ""
            if let sha = firstLine.split(separator: ":").last {
                return sha.trimmingCharacters(in: .whitespaces)
            }
        }
        return "—"
    }
}

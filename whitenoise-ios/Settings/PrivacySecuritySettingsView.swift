import LocalAuthentication
import SwiftUI

struct PrivacySecuritySettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var diagnostics = PrivacySecuritySettingsViewModel()
    @State private var showEraseData = false
    @State private var appLockCapability = AppLockCapability(available: false, biometryType: .none)
    private let privacyPolicyURL = URL(string: "https://www.whitenoise.chat/privacy")

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    WNToggle("Hide Sensitive Content", isOn: Binding(
                        get: { appState.blockScreenshots },
                        set: { appState.blockScreenshots = $0 }
                    ))
                    Text("Hides content in the app switcher and when iOS detects recording or screen sharing. Screenshots are still possible.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    WNToggle(appLockToggleTitle, isOn: Binding(
                        get: { appState.appLock.isEnabled },
                        set: { enabled in Task { await appState.appLock.setEnabled(enabled) } }
                    ))
                    .disabled(!appLockCapability.available)
                    Text(appLockFooter)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                if appState.appLock.isEnabled && appLockCapability.available {
                    Picker("Auto-Lock", selection: Binding(
                        get: { appState.appLock.gracePeriod },
                        set: { appState.appLock.gracePeriod = $0 }
                    )) {
                        ForEach(AppLockGracePeriod.allCases, id: \.self) { period in
                            Text(period.displayName).tag(period)
                        }
                    }
                }
            } header: { Text("App Security") }
            Section {
                NavigationLink("Blocked Users") { BlockedUsersView() }
                if let privacyPolicyURL {
                    Link(destination: privacyPolicyURL) {
                        HStack {
                            Text("Privacy Policy")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            } header: { Text("Privacy") }
            Section {
                NavigationLink {
                    DiagnosticsAndImprovementsView()
                } label: {
                    LabeledContent("Diagnostics & Improvements", value: diagnostics.diagnosticsSummary)
                }
            } header: { Text("Diagnostics") }
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Signs out every profile and permanently removes all White Noise data from this device.")
                        .font(.caption).foregroundStyle(.secondary)
                    WNGrayButton(
                        title: L10n.string("Erase App Data"),
                        isDestructive: true,
                        tintsDestructiveBackground: true
                    ) {
                        showEraseData = true
                    }
                }
                .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20))
            } header: { Text("Device Data") }
        }
        .listSectionSpacing(.compact)
        .productScreen(.settings, section: .privacy)
        .localizedNavigationTitle("Privacy & Security")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            appLockCapability = AppLockCapability.current()
            await diagnostics.reload(using: appState)
        }
        .sheet(isPresented: $showEraseData) { EraseAppDataView().appAppearance() }
    }

    private var appLockToggleTitle: String {
        switch appLockCapability.biometryType {
        case .faceID: L10n.string("Require Face ID")
        case .touchID: L10n.string("Require Touch ID")
        case .opticID: L10n.string("Require Optic ID")
        default: L10n.string("Require passcode")
        }
    }

    private var appLockFooter: String {
        guard appLockCapability.available else {
            return L10n.string("Set an iPhone passcode to lock White Noise.")
        }
        return L10n.string("Locks White Noise when you leave. Your iPhone passcode is available as a fallback.")
    }
}

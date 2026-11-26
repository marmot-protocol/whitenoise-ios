import LocalAuthentication
import SwiftUI

struct PrivacySecuritySettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var diagnostics = PrivacySecuritySettingsViewModel()
    @State private var showEraseData = false
    @State private var appLockCapability = AppLockCapability(available: false, biometryType: .none)
    @State private var appLockToggle = false
    @State private var appLockGracePeriod = AppLockGracePeriod.immediate
    private let privacyPolicyURL = URL(string: "https://www.whitenoise.chat/privacy")

    var body: some View {
        Form {
            Section {
                WNToggle(isOn: Binding(
                    get: { appState.blockScreenshots },
                    set: { appState.blockScreenshots = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hide Sensitive Content")
                        Text("Hides content in the app switcher and when iOS detects recording or screen sharing. Screenshots are still possible.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                WNToggle(isOn: $appLockToggle) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appLockToggleTitle)
                        Text(appLockFooter)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!appLockCapability.available && !appState.appLock.isEnabled)

                if appState.appLock.isEnabled && appLockCapability.available {
                    Picker("Auto-Lock", selection: $appLockGracePeriod) {
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
                                .accessibilityHidden(true)
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
            appLockToggle = appState.appLock.isEnabled
            appLockGracePeriod = appState.appLock.gracePeriod
            await diagnostics.reload(using: appState)
        }
        .onChange(of: appState.appLock.isEnabled) { _, enabled in appLockToggle = enabled }
        .onChange(of: appState.appLock.gracePeriod) { _, period in appLockGracePeriod = period }
        .onChange(of: appLockToggle) { _, enabled in
            Task {
                await appState.appLock.setEnabled(enabled)
                appLockToggle = appState.appLock.isEnabled
            }
        }
        .onChange(of: appLockGracePeriod) { _, period in
            Task {
                await appState.appLock.setGracePeriod(period)
                appLockGracePeriod = appState.appLock.gracePeriod
            }
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

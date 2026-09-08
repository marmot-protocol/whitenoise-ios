import LocalAuthentication
import SwiftUI

struct PrivacySecuritySettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @State private var diagnostics = PrivacySecuritySettingsViewModel()
    @State private var showEraseData = false
    @State private var appLockCapability = AppLockCapability(available: false, biometryType: .none)

    var body: some View {
        Form {
            Section {
                Toggle("Hide Screen in App Switcher", isOn: Binding(
                    get: { appState.blockScreenshots },
                    set: { appState.blockScreenshots = $0 }
                ))
                .tint(appSecurityToggleTint)
            } header: {
                Text("App Security")
            } footer: {
                Text("Hides your conversations and profile details in the app switcher. Screenshots and screen recordings also show a blank screen.")
            }

            Section {
                Toggle(appLockToggleTitle, isOn: Binding(
                    get: { appState.appLock.isEnabled },
                    set: { enabled in Task { await appState.appLock.setEnabled(enabled) } }
                ))
                .tint(appSecurityToggleTint)
                .disabled(!appLockCapability.available)

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
            } footer: {
                Text(appLockFooter)
            }
            Section {
                NavigationLink {
                    DiagnosticsAndImprovementsView()
                        .wnBackButton()
                } label: {
                    LabeledContent("Diagnostics & Improvements", value: diagnostics.diagnosticsSummary)
                }
            } header: { Text("Diagnostics") }
            Section {
                Button("Erase App Data", role: .destructive) { showEraseData = true }
            } header: { Text("Device Data") } footer: {
                Text("Signs out every profile and permanently removes all White Noise data from this iPhone.")
            }
        }
        .localizedNavigationTitle("Privacy & Security")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            appLockCapability = AppLockCapability.current()
            await diagnostics.reload(using: appState)
        }
        .sheet(isPresented: $showEraseData) { EraseAppDataView().appAppearance() }
    }

    private var appSecurityToggleTint: Color {
        colorScheme == .dark ? Color(uiColor: .systemGray) : .black
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
        return L10n.string("Locks White Noise when you leave. Your iPhone passcode can be used if biometric authentication isn't available.")
    }
}

import SwiftUI

struct DiagnosticsSharingDetailsView: View {
    @Environment(AppState.self) private var appState
    var isPrompt = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if isPrompt, let error = appState.diagnosticsConsent.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).foregroundStyle(.orange)
                        Button("Retry") {
                            Task { await appState.diagnosticsConsent.reload(using: appState) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                disclosureSection("Usage and telemetry") {
                    Text("Feature activity and telemetry data include feature usage counts and app performance metrics. Usage data uses temporary session identifiers, and telemetry uses a resettable installation identifier. Neither includes account or group identifiers.")
                }
                disclosureSection("Group diagnostic logs") {
                    Text("Group diagnostic logs help investigate group reliability and consistency. They include technical identifiers, timestamps, and membership changes, using hashed references instead of member identities. They never contain message contents, profile names, group names, or private keys.")
                    Text("Enabling group diagnostic log sharing may upload logs already stored on this device.")
                }
                disclosureSection("Data retention") {
                    Text("Group diagnostic logs are deleted from our servers after 30 days, telemetry after 90 days, and product analytics after 180 days.")
                }
                disclosureSection("Turning sharing off") {
                    Text("Turning these off stops new recording and prevents new automatic uploads. An automatic log upload batch already in progress may finish. Turning these off does not delete data already stored on this device or our servers.")
                }
                if let privacyPolicyURL = URL(string: "https://www.whitenoise.chat/privacy") {
                    Link(destination: privacyPolicyURL) {
                        Text("Privacy Policy").underline()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .font(.body)
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationTitle("What’s shared")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func disclosureSection<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

struct DiagnosticsPromptToolbar: ViewModifier {
    @Environment(AppState.self) private var appState
    var isFinishing: Bool
    var onFinish: (() -> Void)?

    func body(content: Content) -> some View {
        content.toolbar {
            if let onFinish {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onFinish)
                        .disabled(isFinishing || !appState.diagnosticsConsent.available || appState.diagnosticsConsent.errorMessage != nil)
                }
            }
        }
    }
}

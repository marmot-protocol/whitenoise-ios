import SwiftUI

struct DiagnosticsAndImprovementsView: View {
    @Environment(AppState.self) private var appState
    @State private var model = PrivacySecuritySettingsViewModel()
    @State private var showSharingDetails = false
    var isPrompt = false
    var isFinishing = false
    var onFinish: (() -> Void)?

    var body: some View {
        Form {
            Section {
                analyticsToggle
                loggingToggle
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if let explanation = appState.diagnosticsConsent.explanation {
                        Text(explanation)
                    }
                    Text(sharingSummary)
                        .tint(.primary)
                        .environment(\.openURL, OpenURLAction { _ in
                            showSharingDetails = true
                            return .handled
                        })
                }
            }
            if !isPrompt {
                if let snapshot = appState.diagnosticsConsent.snapshot {
                    Section { Text(snapshot.exporterSummary).foregroundStyle(.secondary) }
                }
                Section {
                    LabeledContent("On This iPhone", value: model.storedLogSize)
                    Button("Clear Diagnostic Logs", role: .destructive) {
                        model.showDeleteAuditLogsConfirmation = true
                    }
                    .disabled(model.auditDeleteDisabled || model.auditFileRows.isEmpty)
                } header: {
                    Text("Stored Diagnostic Logs")
                } footer: {
                    Text("Clearing diagnostic logs deletes logs from this device only. It does not delete copies already uploaded to White Noise servers or turn off recording and automatic uploads.")
                }
            }
            if let error = appState.diagnosticsConsent.errorMessage ?? model.errorMessage ?? model.auditErrorMessage {
                Section {
                    Text(error).foregroundStyle(.orange)
                    Button("Retry") { Task { await reload() } }
                }
            }
        }
        .navigationTitle(isPrompt ? "Help Improve White Noise" : "Diagnostics & Improvements")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showSharingDetails) {
            DiagnosticsSharingDetailsView(isFinishing: isFinishing, onFinish: onFinish)
        }
        .modifier(DiagnosticsPromptToolbar(isFinishing: isFinishing, onFinish: onFinish))
        .task(id: appState.runtimeGeneration) { await reload() }
        .productScreen(.diagnostics, section: .diagnostics)
        .alert("Clear diagnostic logs?", isPresented: $model.showDeleteAuditLogsConfirmation) {
            Button("Clear Logs", role: .destructive) { Task { await model.deleteAllAuditLogs(using: appState) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes recorded diagnostic activity for all profiles from this device. Your logging preference won’t change.")
        }
    }

    private var sharingSummary: AttributedString {
        var summary = AttributedString(isPrompt
            ? L10n.string("These choices apply to all accounts on this device. You can change them anytime in Settings → Privacy & Security → Diagnostics & Improvements.")
            : L10n.string("These choices apply to all accounts on this device."))
        var details = AttributedString(L10n.string("What’s shared"))
        details.link = URL(string: "whitenoise:diagnostics-sharing")
        details.underlineStyle = .single
        summary += AttributedString(" ")
        summary += details
        return summary
    }

    private func reload() async {
        await appState.diagnosticsConsent.reload(using: appState)
        if !isPrompt { await model.reload(using: appState) }
    }

    private var analyticsToggle: some View {
        WNToggle(isOn: Binding(
            get: { appState.diagnosticsConsent.usageEnabled },
            set: { enabled in Task { await appState.diagnosticsConsent.setUsage(enabled, using: appState) } }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Share usage and telemetry")
                Text("Automatically shares feature-use counts and app performance with White Noise.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(isFinishing || !appState.diagnosticsConsent.available)
    }

    private var loggingToggle: some View {
        WNToggle(isOn: Binding(
            get: { appState.diagnosticsConsent.auditEnabled },
            set: { enabled in Task { await appState.diagnosticsConsent.setAudit(enabled, using: appState) } }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Share group diagnostic logs")
                Text("Automatically shares technical group logs, including group and message identifiers. May include logs already on this device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(isFinishing || !appState.diagnosticsConsent.available)
    }
}

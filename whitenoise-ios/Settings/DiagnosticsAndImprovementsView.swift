import SwiftUI

struct DiagnosticsAndImprovementsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var model = PrivacySecuritySettingsViewModel()
    var isPrompt = false

    var body: some View {
        Form {
            Section {
                analyticsToggle
                loggingToggle
            } header: {
                if isPrompt {
                    Text("Help us understand how White Noise is used and make messaging more reliable.")
                        .font(.body).foregroundStyle(Color.primary).textCase(nil)
                        .padding(.bottom, 12)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if let explanation = appState.diagnosticsConsent.explanation { Text(explanation) }
                    sharingDisclosure
                }
                .padding(.top, 12)
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
        .toolbar {
            if isPrompt {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if await appState.diagnosticsConsent.finishPrompt(using: appState) { dismiss() }
                        }
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel("Done")
                    .disabled(!appState.diagnosticsConsent.available || appState.diagnosticsConsent.errorMessage != nil)
                }
            }
        }
        .interactiveDismissDisabled(isPrompt)
        .task(id: appState.runtimeGeneration) { await reload() }
        .productScreen(.diagnostics, section: .diagnostics)
        .alert("Clear diagnostic logs?", isPresented: $model.showDeleteAuditLogsConfirmation) {
            Button("Clear Logs", role: .destructive) { Task { await model.deleteAllAuditLogs(using: appState) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes recorded diagnostic activity for all profiles from this device. Your logging preference won’t change.")
        }
    }

    private func reload() async {
        await appState.diagnosticsConsent.reload(using: appState)
        if !isPrompt { await model.reload(using: appState) }
    }

    @ViewBuilder
    private var sharingDisclosure: some View {
        Text("Feature activity and telemetry data include feature usage counts and app performance metrics. Usage data uses temporary session identifiers, and telemetry uses a resettable installation identifier. Neither includes account or group identifiers.")
        Text("Group diagnostic logs help investigate group reliability and consistency. They include technical identifiers, timestamps, and membership changes, using hashed references instead of member identities. They never contain message contents, profile names, group names, or private keys.")
        Text("Enabling group diagnostic log sharing may upload logs already stored on this device.")
        Text("Group diagnostic logs are deleted from our servers after 30 days, telemetry after 90 days, and product analytics after 180 days.")
        Text("Turning these off stops new recording and prevents new automatic uploads. An automatic log upload batch already in progress may finish. Turning these off does not delete data already stored on this device or our servers.")
    }

    private var analyticsToggle: some View {
        Toggle(isOn: Binding(
            get: { appState.diagnosticsConsent.usageEnabled },
            set: { enabled in Task { await appState.diagnosticsConsent.setUsage(enabled, using: appState) } }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Share usage and telemetry")
                Text("Automatically gathers and uploads feature activity and telemetry metrics for every profile on this device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(!appState.diagnosticsConsent.available)
    }

    private var loggingToggle: some View {
        Toggle(isOn: Binding(
            get: { appState.diagnosticsConsent.auditEnabled },
            set: { enabled in Task { await appState.diagnosticsConsent.setAudit(enabled, using: appState) } }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Share group diagnostic logs")
                Text("Automatically gathers and uploads technical logs about groups for every profile on this device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(!appState.diagnosticsConsent.available)
    }
}

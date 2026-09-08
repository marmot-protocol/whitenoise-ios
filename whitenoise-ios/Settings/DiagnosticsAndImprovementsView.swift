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
                    Text("Help us understand how White Noise is used and make messaging more reliable. Sharing is optional.")
                        .font(.body).foregroundStyle(Color.primary).textCase(nil)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if let explanation = appState.diagnosticsConsent.explanation { Text(explanation) }
                    Text("Usage includes approved, bucketed activity and temporary session IDs, without message contents or account and group identifiers. The Aptabase server receives your IP address, uses IP and user-agent information for daily activity grouping, and adds approximate country and region. Diagnostics includes a random installation identifier that changes after you turn sharing off. Turning this off stops both pipelines; already transmitted data cannot be recalled. Diagnostic logging is separate.")
                    Text("Shares sanitized technical activity from all profiles on this device with White Noise. Message content is excluded and identifiers are obscured. Turning this off stops new logging and automatic sharing, and keeps existing local logs.")
                    Text(L10n.formatted("Operator: %@", appState.client?.productConfig.operatorDisplayName ?? "White Noise"))
                    Text(appState.client?.productConfig.retentionDisclosure ?? L10n.string("Retention policy has not yet been verified for this development build."))
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
                } header: { Text("Stored Diagnostic Logs") }
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Continue") {
                        Task {
                            if await appState.diagnosticsConsent.finishPrompt(using: appState) { dismiss() }
                        }
                    }
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

    private var analyticsToggle: some View {
        Toggle(isOn: Binding(
            get: { appState.diagnosticsConsent.usageEnabled },
            set: { enabled in Task { await appState.diagnosticsConsent.setUsage(enabled, using: appState) } }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Share usage and diagnostics")
                Text("Feature activity and reliability metrics, with temporary sessions and a resettable diagnostic identifier.")
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
                Text("Share Diagnostic Logs")
                Text("Technical logs from every profile on this device, shared separately.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(!appState.diagnosticsConsent.available)
    }
}

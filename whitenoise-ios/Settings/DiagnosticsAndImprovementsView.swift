import SwiftUI

struct DiagnosticsAndImprovementsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var model = PrivacySecuritySettingsViewModel()
    var isPrompt = false

    var body: some View {
        Form {
            if isPrompt {
                Section {
                    preferences
                } header: {
                    Text("Help us make messaging without a central point of control more reliable. Analytics and diagnostic logs are optional and can be changed in Settings.")
                        .font(.body).foregroundStyle(Color.primary).textCase(nil).padding(.bottom)
                } footer: {
                    Text("These choices apply to all profiles on this device. Analytics exclude messages, media, contacts, profile details, and keys. Diagnostic logs obscure identifiers and are sent to White Noise for troubleshooting.")
                }
            } else {
                Section {
                    analyticsToggle
                } footer: {
                    Text("Shares anonymous reliability and performance data from this device. Messages, media, contacts, profile details, and keys are excluded. Turning this off stops sharing analytics.")
                }
                Section {
                    loggingToggle
                } footer: {
                    Text("Shares sanitized technical activity from all profiles on this device with White Noise. Message content is excluded and identifiers are obscured. Turning this off stops new logging and automatic sharing, and keeps existing local logs.")
                }
                Section {
                    LabeledContent("On This iPhone", value: model.storedLogSize)
                    Button("Clear Diagnostic Logs", role: .destructive) {
                        model.showDeleteAuditLogsConfirmation = true
                    }
                    .disabled(model.auditDeleteDisabled || model.auditFileRows.isEmpty)
                } header: { Text("Stored Diagnostic Logs") }
            }
            if let error = model.errorMessage ?? model.auditErrorMessage ?? model.telemetryErrorMessage {
                Section {
                    Text(error).foregroundStyle(.orange)
                    Button("Retry") { Task { await model.reload(using: appState) } }
                }
            }
        }
        .navigationTitle(isPrompt ? "Help Improve White Noise" : "Diagnostics & Improvements")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isPrompt {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
                }
            }
        }
        .task(id: appState.runtimeGeneration) { await model.reload(using: appState) }
        .alert("Clear diagnostic logs?", isPresented: $model.showDeleteAuditLogsConfirmation) {
            Button("Clear Logs", role: .destructive) { Task { await model.deleteAllAuditLogs(using: appState) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes recorded diagnostic activity for all profiles from this device. Your logging preference won’t change.")
        }
    }

    private var preferences: some View {
        Group { analyticsToggle; loggingToggle }
    }

    private var analyticsToggle: some View {
        Toggle("Share Anonymous Analytics", isOn: Binding(
            get: { model.telemetrySettings?.exportEnabled ?? false },
            set: { enabled in Task { await model.setTelemetryEnabled(enabled, using: appState) } }
        ))
        .disabled(model.telemetryToggleDisabled)
    }

    private var loggingToggle: some View {
        Toggle("Share Diagnostic Logs", isOn: Binding(
            get: { model.auditSettings?.enabled ?? false },
            set: { enabled in Task { await model.setAuditEnabled(enabled, using: appState) } }
        ))
        .disabled(model.auditToggleDisabled)
    }
}

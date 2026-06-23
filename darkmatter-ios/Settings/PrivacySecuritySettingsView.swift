import SwiftUI

struct PrivacySecuritySettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var model = PrivacySecuritySettingsViewModel()

    var body: some View {
        @Bindable var model = model
        return Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.telemetrySettings?.exportEnabled ?? false },
                    set: { enabled in Task { await model.setTelemetryEnabled(enabled, using: appState) } }
                )) {
                    Label("Anonymous Telemetry", systemImage: "chart.line.uptrend.xyaxis")
                }
                .disabled(model.telemetryToggleDisabled)

                if model.telemetrySaving {
                    ProgressView("Saving")
                }
            } header: {
                Text("Telemetry")
            } footer: {
                Text(telemetryFooter)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { appState.developerMode },
                    set: { appState.developerMode = $0 }
                )) {
                    Label("Developer mode", systemImage: "apple.terminal")
                }

                if appState.developerMode {
                    Toggle(isOn: Binding(
                        get: { appState.streamingDebugMode },
                        set: { appState.streamingDebugMode = $0 }
                    )) {
                        Label("Streaming debug", systemImage: "waveform.path.ecg")
                    }

                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Open Diagnostics", systemImage: "stethoscope")
                    }
                }
            } header: {
                Text("Developer")
            } footer: {
                Text("Adds debugging tools, including MLS group internals and diagnostics. Streaming debug shows every agent-stream MLS event and live QUIC update in the conversation timeline. The diagnostics console can log message text and account activity on this device.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.auditSettings?.enabled ?? false },
                    set: { enabled in Task { await model.setAuditEnabled(enabled, using: appState) } }
                )) {
                    Label("Audit Logging", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(model.auditSaving || model.auditSettings == nil)

                if model.auditSaving {
                    ProgressView("Saving")
                }
            } header: {
                Text("Audit Logging")
            } footer: {
                Text("Writes local audit JSONL files for forensic review. Toggling applies immediately to running sessions.")
            }

            Section {
                if model.filesLoading && model.auditFileRows.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("Loading audit logs")
                        Spacer()
                    }
                    .padding(.vertical, 16)
                } else if model.auditFileRows.isEmpty {
                    Text("No audit logs on this device.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.auditFileRows) { row in
                        auditFileRow(row)
                    }

                    Button(role: .destructive) {
                        model.showDeleteAuditLogsConfirmation = true
                    } label: {
                        Label("Delete All Audit Logs", systemImage: "trash")
                    }
                    .disabled(model.auditDeleting || model.auditSaving)
                }

                if model.auditDeleting {
                    ProgressView("Deleting audit logs")
                }
            } header: {
                Text("Audit Log Files")
            } footer: {
                if !model.auditFileRows.isEmpty {
                    Text("Deletes every local audit JSONL file on this device. Live recorders rotate to fresh files when audit logging is still on.")
                }
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            if let savedAt = model.savedAt {
                Section {
                    Label(
                        L10n.formatted("Saved %@", savedAt.formatted(.relative(presentation: .named))),
                        systemImage: "checkmark.seal.fill"
                    )
                    .foregroundStyle(.green)
                    .font(.callout)
                }
            }
        }
        .navigationTitle("Privacy & Security")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.reload(using: appState) }
        .refreshable { await model.reload(using: appState) }
        .alert(
            "Delete all audit logs?",
            isPresented: $model.showDeleteAuditLogsConfirmation
        ) {
            Button("Delete All Audit Logs", role: .destructive) {
                Task { await model.deleteAllAuditLogs(using: appState) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every local audit JSONL file on this device.")
        }
    }

    private var telemetryFooter: String {
        "Anonymous telemetry helps improve reliability and performance."
    }

    @ViewBuilder
    private func auditFileRow(_ row: AuditFileRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.fileName)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Text(row.detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(row.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }
}

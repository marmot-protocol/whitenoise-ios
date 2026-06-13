import SwiftUI

struct PrivacySecuritySettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var telemetrySettings: PrivacyTelemetrySettingsProjection?
    @State private var auditSettings: PrivacyAuditSettingsProjection?
    @State private var auditFileRows: [AuditFileRow] = []
    @State private var telemetrySaving = false
    @State private var auditSaving = false
    @State private var auditDeleting = false
    @State private var showDeleteAuditLogsConfirmation = false
    @State private var filesLoading = false
    @State private var errorMessage: String?
    @State private var savedAt: Date?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { telemetrySettings?.exportEnabled ?? false },
                    set: { enabled in Task { await setTelemetryEnabled(enabled) } }
                )) {
                    Label("Anonymous Telemetry", systemImage: "chart.line.uptrend.xyaxis")
                }
                .disabled(telemetryToggleDisabled)

                if telemetrySaving {
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
                    get: { auditSettings?.enabled ?? false },
                    set: { enabled in Task { await setAuditEnabled(enabled) } }
                )) {
                    Label("Audit Logging", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(auditSaving || auditSettings == nil)

                if auditSaving {
                    ProgressView("Saving")
                }
            } header: {
                Text("Audit Logging")
            } footer: {
                Text("Writes local audit JSONL files for forensic review. Toggling applies immediately to running sessions.")
            }

            Section {
                if filesLoading && auditFileRows.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("Loading audit logs")
                        Spacer()
                    }
                    .padding(.vertical, 16)
                } else if auditFileRows.isEmpty {
                    Text("No audit logs on this device.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(auditFileRows) { row in
                        auditFileRow(row)
                    }

                    Button(role: .destructive) {
                        showDeleteAuditLogsConfirmation = true
                    } label: {
                        Label("Delete All Audit Logs", systemImage: "trash")
                    }
                    .disabled(auditDeleting || auditSaving)
                }

                if auditDeleting {
                    ProgressView("Deleting audit logs")
                }
            } header: {
                Text("Audit Log Files")
            } footer: {
                if !auditFileRows.isEmpty {
                    Text("Deletes every local audit JSONL file on this device. Live recorders rotate to fresh files when audit logging is still on.")
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            if let savedAt {
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
        .task { await reload() }
        .refreshable { await reload() }
        .alert(
            "Delete all audit logs?",
            isPresented: $showDeleteAuditLogsConfirmation
        ) {
            Button("Delete All Audit Logs", role: .destructive) {
                Task { await deleteAllAuditLogs() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every local audit JSONL file on this device.")
        }
    }

    private var telemetryToggleDisabled: Bool {
        telemetrySaving || telemetrySettings == nil
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

    @MainActor
    private func reload() async {
        filesLoading = true
        errorMessage = nil
        defer { filesLoading = false }

        do {
            let projection = try await appState.privacySecuritySettingsProjection()
            telemetrySettings = projection.telemetrySettings
            auditSettings = projection.auditSettings
            auditFileRows = projection.auditFileRows
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func reloadAuditFiles() async {
        filesLoading = true
        errorMessage = nil
        defer { filesLoading = false }

        do {
            auditFileRows = try await appState.auditLogFileRows()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func setTelemetryEnabled(_ enabled: Bool) async {
        guard let current = telemetrySettings else { return }
        telemetrySaving = true
        errorMessage = nil
        telemetrySettings = current.updatingExportEnabled(enabled)
        defer { telemetrySaving = false }

        do {
            telemetrySettings = PrivacyTelemetrySettingsProjection(
                settings: try await appState.setRelayTelemetryExportEnabled(enabled)
            )
            savedAt = Date()
            Haptics.success()
        } catch {
            telemetrySettings = current
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func deleteAllAuditLogs() async {
        auditDeleting = true
        errorMessage = nil
        defer { auditDeleting = false }

        do {
            try await appState.deleteAllAuditLogFiles()
            savedAt = Date()
            Haptics.success()
            await reloadAuditFiles()
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func setAuditEnabled(_ enabled: Bool) async {
        guard let current = auditSettings else { return }
        auditSaving = true
        errorMessage = nil
        auditSettings = PrivacyAuditSettingsProjection(enabled: enabled)
        defer { auditSaving = false }

        do {
            auditSettings = PrivacyAuditSettingsProjection(
                settings: try await appState.setAuditLogEnabled(enabled)
            )
            savedAt = Date()
            Haptics.success()
            await reloadAuditFiles()
        } catch {
            auditSettings = current
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }
}

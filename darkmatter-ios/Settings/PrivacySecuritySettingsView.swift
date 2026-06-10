import SwiftUI
import MarmotKit

struct PrivacySecuritySettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var telemetrySettings: RelayTelemetrySettingsFfi?
    @State private var auditSettings: AuditLogSettingsFfi?
    @State private var auditFiles: [AuditLogFileFfi] = []
    @State private var telemetrySaving = false
    @State private var auditSaving = false
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
                    ProgressView("Restarting")
                }
            } header: {
                Text("Audit Logging")
            } footer: {
                Text("Writes local audit JSONL files for forensic review. Changing this restarts the local runtime immediately.")
            }

            Section {
                if filesLoading && auditFiles.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("Loading audit logs")
                        Spacer()
                    }
                    .padding(.vertical, 16)
                } else if auditFiles.isEmpty {
                    Text("No audit logs on this device.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(auditFiles, id: \.path) { file in
                        auditFileRow(file)
                    }
                }
            } header: {
                Text("Audit Log Files")
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
                    Label("Saved \(savedAt.formatted(.relative(presentation: .named)))",
                          systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                }
            }
        }
        .navigationTitle("Privacy & Security")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
    }

    private var telemetryToggleDisabled: Bool {
        telemetrySaving || telemetrySettings == nil
    }

    private var telemetryFooter: String {
        "Anonymous telemetry helps improve reliability and performance."
    }

    @ViewBuilder
    private func auditFileRow(_ file: AuditLogFileFfi) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(file.fileName)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Text(auditFileDetails(file))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(file.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    @MainActor
    private func reload() async {
        errorMessage = nil

        do {
            telemetrySettings = try appState.relayTelemetrySettings()
            auditSettings = try appState.auditLogSettings()
            auditFiles = try appState.auditLogFiles()
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
            auditFiles = try appState.auditLogFiles()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func setTelemetryEnabled(_ enabled: Bool) async {
        guard let current = telemetrySettings else { return }
        telemetrySaving = true
        errorMessage = nil
        telemetrySettings = RelayTelemetrySettingsFfi(
            exportEnabled: enabled,
            exportIntervalSeconds: current.exportIntervalSeconds
        )
        defer { telemetrySaving = false }

        do {
            telemetrySettings = try await appState.setRelayTelemetryExportEnabled(enabled)
            savedAt = Date()
            Haptics.success()
        } catch {
            telemetrySettings = current
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func setAuditEnabled(_ enabled: Bool) async {
        guard let current = auditSettings else { return }
        auditSaving = true
        errorMessage = nil
        auditSettings = AuditLogSettingsFfi(enabled: enabled)
        defer { auditSaving = false }

        do {
            auditSettings = try await appState.setAuditLogEnabled(enabled)
            savedAt = Date()
            Haptics.success()
            await reloadAuditFiles()
        } catch {
            auditSettings = current
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }

    private func auditFileDetails(_ file: AuditLogFileFfi) -> String {
        var parts = [byteCount(file.sizeBytes)]
        if let modifiedAtMs = file.modifiedAtMs {
            let date = Date(timeIntervalSince1970: TimeInterval(modifiedAtMs) / 1_000)
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        parts.append(shortAccountRef(file.accountRef))
        return parts.joined(separator: " - ")
    }

    private func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private func shortAccountRef(_ ref: String) -> String {
        let capped = String(ref.prefix(64))
        guard capped.count > 14 else { return capped }
        return "\(capped.prefix(8))...\(capped.suffix(6))"
    }
}

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
    @State private var uploadingPath: String?
    @State private var pendingUpload: AuditLogFileFfi?
    @State private var errorMessage: String?
    @State private var savedAt: Date?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { telemetrySettings?.exportEnabled ?? false },
                    set: { enabled in Task { await setTelemetryEnabled(enabled) } }
                )) {
                    Label("Analytics & Telemetry", systemImage: "chart.line.uptrend.xyaxis")
                }
                .disabled(telemetryToggleDisabled)

                if telemetrySaving {
                    ProgressView("Saving")
                }
            } header: {
                Text("Analytics & Telemetry")
            } footer: {
                Text(telemetryFooter)
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

                Button {
                    Task { await reloadAuditFiles() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(filesLoading || uploadingPath != nil)
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
        .confirmationDialog(
            "Send audit log?",
            isPresented: pendingUploadBinding,
            titleVisibility: .visible
        ) {
            Button("Send Audit Log") {
                guard let pendingUpload else { return }
                Task { await upload(pendingUpload) }
            }
            Button("Cancel", role: .cancel) {
                pendingUpload = nil
            }
        } message: {
            Text("Uploads \(pendingUpload?.fileName ?? "the selected audit log") to \(appState.telemetryBuildConfig.auditUploadEndpoint).")
        }
    }

    private var telemetryToggleDisabled: Bool {
        guard !telemetrySaving, telemetrySettings != nil else { return true }
        if appState.telemetryBuildConfig.telemetryCredentialsAvailable {
            return false
        }
        return telemetrySettings?.exportEnabled != true
    }

    private var telemetryFooter: String {
        if appState.telemetryBuildConfig.telemetryCredentialsAvailable {
            return "Sends aggregate relay/runtime metrics for this device."
        }
        return "Telemetry credentials are not configured for this build."
    }

    private var pendingUploadBinding: Binding<Bool> {
        Binding(
            get: { pendingUpload != nil },
            set: { if !$0 { pendingUpload = nil } }
        )
    }

    @ViewBuilder
    private func auditFileRow(_ file: AuditLogFileFfi) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(file.fileName)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(auditFileDetails(file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                pendingUpload = file
            } label: {
                if uploadingPath == file.path {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Send", systemImage: "paperplane.fill")
                }
            }
            .buttonStyle(.borderless)
            .disabled(uploadingPath != nil)
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
            telemetrySettings = try appState.setRelayTelemetryExportEnabled(enabled)
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

    @MainActor
    private func upload(_ file: AuditLogFileFfi) async {
        guard uploadingPath == nil else { return }
        uploadingPath = file.path
        errorMessage = nil
        defer {
            uploadingPath = nil
            pendingUpload = nil
        }

        do {
            let result = try await appState.postAuditLogFile(file)
            Haptics.success()
            appState.present(
                .success(
                    "Audit log sent",
                    message: "\(byteCount(result.bytesSent)) uploaded"
                )
            )
            await reloadAuditFiles()
        } catch {
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

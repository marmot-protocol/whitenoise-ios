import SwiftUI
import MarmotKit
import UniformTypeIdentifiers

struct DeveloperToolsSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var model = PrivacySecuritySettingsViewModel()
    @State private var exportDocument = DiagnosticLogDocument(text: "")
    @State private var showExport = false
    @State private var exporting = false
    @State private var exportError: String?
    @State private var quarantinedGroupsModel = QuarantinedGroupsViewModel()

    var body: some View {
        @Bindable var model = model
        return Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("For development and testing only")
                        Text("These tools can expose technical information and change how the app behaves.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Toggle("Developer Tools", isOn: Binding(
                    get: { appState.developerMode },
                    set: { appState.developerMode = $0 }
                ))
            } footer: {
                Text("Enable technical tools for this profile.")
            }

            if appState.developerMode {
                Section {
                    Toggle("Debug Mode", isOn: Binding(
                        get: { appState.streamingDebugMode },
                        set: { appState.streamingDebugMode = $0 }
                    ))

                    NavigationLink {
                        DiagnosticsView()
                            .wnBackButton()
                    } label: {
                        Label("Debug Events", systemImage: "stethoscope")
                    }
                } header: {
                    Text("Debugging")
                } footer: {
                    Text("Debug Mode adds technical conversation details intended for development and testing.")
                }

                Section {
                    NavigationLink {
                        KeyPackagesView()
                            .wnBackButton()
                    } label: {
                        Label("Key Packages", systemImage: "shippingbox")
                    }

                    NavigationLink {
                        QuarantinedGroupsView(model: quarantinedGroupsModel)
                            .wnBackButton()
                    } label: {
                        HStack {
                            Label("Quarantined Groups", systemImage: "exclamationmark.shield")
                            Spacer()
                            if quarantinedGroupsModel.isLoading {
                                ProgressView().controlSize(.small)
                            } else if quarantinedGroupsModel.loadError != nil {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.orange)
                                    .accessibilityLabel("Couldn't load quarantined groups")
                            } else {
                                Text(quarantinedGroupsModel.groups.count, format: .number)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                Section {
                    LabeledContent("Diagnostic Logging", value: model.auditSettings?.enabled == true ? L10n.string("On") : L10n.string("Off"))
                    if model.auditFileRows.contains(where: { $0.sizeBytes > 0 }) {
                        ForEach(model.auditFileRows.filter { $0.sizeBytes > 0 }) { row in auditFileRow(row) }
                        Button("Export Diagnostic Logs", systemImage: "square.and.arrow.up") { exportLogs() }
                            .disabled(exporting)
                    } else {
                        Text("There are no logs.").foregroundStyle(.secondary)
                    }
                } header: { Text("Diagnostic Logs") } footer: {
                    Text("Configure or clear logs in Privacy & Security → Diagnostics & Improvements. Export saves a sanitized activity summary without event payloads.")
                }
            }

            if let errorMessage = model.errorMessage ?? model.auditErrorMessage {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                        Button("Retry") {
                            Task { await model.reload(using: appState) }
                        }
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Built on") {
                    Text(marmotBuildLabel)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .localizedNavigationTitle("Developer Tools")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appState.activeAccountRef) { await model.reload(using: appState) }
        .task(id: appState.developerMode ? appState.activeAccountRef : nil) {
            if appState.developerMode {
                await quarantinedGroupsModel.reload(using: appState)
            } else {
                quarantinedGroupsModel.reset()
            }
        }
        .refreshable {
            await model.reload(using: appState)
            if appState.developerMode {
                await quarantinedGroupsModel.reload(using: appState)
            }
        }
        .fileExporter(isPresented: $showExport, document: exportDocument, contentType: .plainText,
                      defaultFilename: "White Noise Diagnostic Logs") { result in
            if case .failure = result { exportError = L10n.string("Couldn’t save diagnostic logs. Try again.") }
            exportDocument = DiagnosticLogDocument(text: "")
        }
        .alert("Couldn’t Export Diagnostic Logs", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(exportError ?? "") }
    }

    private func exportLogs() {
        guard !exporting else { return }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                let text = try await appState.diagnosticLogExport()
                exportDocument = DiagnosticLogDocument(text: text)
                showExport = true
            } catch {
                exportError = L10n.string("Couldn’t read diagnostic logs. Try again.")
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var marmotBuildLabel: String {
        MarmotKitBuildLabel.text(tag: MarmotKitVersion.mdkTag, sha: MarmotKitVersion.mdkSHA)
    }

    private func auditFileRow(_ row: AuditFileRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.fileName)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Text(row.detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

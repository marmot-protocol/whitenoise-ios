import MarmotKit
import SwiftUI

struct DiagnosticsAndImprovementsView: View {
    @Environment(AppState.self) private var appState
    @State private var model = PrivacySecuritySettingsViewModel()
    @State private var retention = AuditLogRetentionModel()
    @State private var hasLoadedLogs = false
    @State private var showSharingDetails = false
    @State private var showSharingDetailsSheet = false
    var isPrompt = false
    var isFinishing = false
    var onFinish: (() -> Void)?

    var body: some View {
        Form {
            Section {
                analyticsToggle
                loggingToggle
                if let notice = sharingAvailabilityNotice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
                        .listRowSeparator(.visible, edges: .top)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if let explanation = appState.diagnosticsConsent.explanation {
                        Text(explanation)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(sharingSummary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .tint(.primary)
                        .environment(\.openURL, OpenURLAction { _ in
                            if isPrompt {
                                showSharingDetails = true
                            } else {
                                showSharingDetailsSheet = true
                            }
                            return .handled
                        })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !isPrompt {
                Section {
                    retentionRow
                    VStack(alignment: .leading, spacing: 12) {
                        if !hasLoadedLogs || model.filesLoading {
                            ProgressView("Loading…")
                        } else if model.errorMessage != nil || model.auditErrorMessage != nil || model.auditSettings == nil {
                            Text("Unavailable").foregroundStyle(.secondary)
                        } else if model.auditFileRows.isEmpty {
                            Text("No diagnostic logs stored").foregroundStyle(.secondary)
                        } else {
                            LabeledContent("Stored on this device", value: model.storedLogSize)
                            Text("Clearing removes local logs only. Uploaded copies and sharing settings stay unchanged.")
                                .font(.caption).foregroundStyle(.secondary)
                            WNGrayButton(title: L10n.string("Clear Diagnostic Logs"), isDestructive: true) {
                                model.showDeleteAuditLogsConfirmation = true
                            }
                            .disabled(model.auditDeleteDisabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20))
                } header: {
                    Text("Stored Diagnostic Logs")
                } footer: {
                    Text("Logs older than this are deleted from this device, including ones not uploaded yet.")
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
            DiagnosticsSharingDetailsView(isPrompt: isPrompt)
        }
        .sheet(isPresented: $showSharingDetailsSheet) {
            NavigationStack {
                DiagnosticsSharingDetailsView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            WNIconButton(title: "Close", systemImage: "xmark", chrome: .container) {
                                showSharingDetailsSheet = false
                            }
                        }
                    }
            }
            .appAppearance()
        }
        .modifier(DiagnosticsPromptToolbar(
            isFinishing: isFinishing,
            onFinish: showSharingDetails ? nil : onFinish
        ))
        .task(id: appState.runtimeGeneration) { await reload() }
        .productScreen(.diagnostics, section: .diagnostics)
        .alert(
            "Delete older logs?",
            isPresented: Binding(
                get: { retention.pendingShorterDays != nil },
                set: { if !$0 { retention.pendingShorterDays = nil } }
            ),
            presenting: retention.pendingShorterDays
        ) { days in
            Button("Delete Older Logs", role: .destructive) {
                Task {
                    await retention.confirmShorter(days: days, using: appState) {
                        await model.reloadAuditFilesAfterRetentionChange(
                            cutoffMs: AuditLogRetentionPresentation.cutoffMs(days: days),
                            using: appState
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) { retention.pendingShorterDays = nil }
        } message: { days in
            Text(L10n.formatted(
                "Keeping logs for %@ deletes older logs on this device now, including ones not uploaded yet.",
                AuditLogRetentionPresentation.title(days: days)
            ))
        }
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
        if !isPrompt {
            await retention.load(using: appState)
            await model.reload(using: appState)
            if !Task.isCancelled { hasLoadedLogs = true }
        }
    }

    @ViewBuilder
    private var retentionRow: some View {
        if let current = retention.retention {
            if retention.isBusy {
                LabeledContent("Keep Logs For") { ProgressView() }
            } else {
                Picker("Keep Logs For", selection: Binding(
                    get: { current.maxAgeDays },
                    set: { days in Task { await retention.choose(days: days, using: appState) } }
                )) {
                    ForEach(AuditLogRetentionPresentation.options(including: current.maxAgeDays), id: \.self) { days in
                        Text(AuditLogRetentionPresentation.title(days: days)).tag(days)
                    }
                }
                .pickerStyle(.menu)
            }
        } else if retention.loadFailed {
            Button("Retry Loading Log Retention") { Task { await retention.load(using: appState) } }
        }
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

    private var sharingAvailabilityNotice: String? {
        guard appState.diagnosticsConsent.usageEnabled else { return nil }
        return appState.diagnosticsConsent.snapshot?.unavailableSharingNotice
    }
}

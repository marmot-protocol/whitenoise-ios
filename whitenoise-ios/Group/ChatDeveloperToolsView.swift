import SwiftUI
import UIKit
import MarmotKit

nonisolated enum ChatDeveloperToolsPresentation {
    static func lifecycleLabel(
        membership: SelfMembershipFfi,
        leaveRequestPending: Bool,
        isDisbanding: Bool,
        isDisbanded: Bool
    ) -> String {
        if isDisbanded { return L10n.string("Ended") }
        if isDisbanding { return L10n.string("Ending") }
        if leaveRequestPending { return L10n.string("Leaving") }
        switch membership {
        case .member: return L10n.string("Active")
        case .left: return L10n.string("Left")
        case .removed: return L10n.string("Removed")
        }
    }
}

struct ChatDeveloperToolsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showResetConfirmation = false
    @Environment(AppState.self) private var appState
    @Bindable var model: GroupDetailsViewModel
    @Bindable var conversation: ConversationViewModel

    var body: some View {
        Form {
            conversationSection
            deliverySection
            maintenanceSection
            diagnosticsSection
            resetSection
        }
        .navigationTitle("Chat Developer Tools")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: conversation.groupMlsRefreshGeneration) {
            await model.refreshVisibleDebugState(using: appState)
        }
        .refreshable {
            await model.refreshGroupManagementAndNotify()
            await model.refreshVisibleDebugState(using: appState)
        }
        .alert(
            "Export failed",
            isPresented: Binding(
                get: { model.transcriptExportError != nil },
                set: { if !$0 { model.transcriptExportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.transcriptExportError = nil }
        } message: {
            Text(model.transcriptExportError ?? "")
        }
        .alert("Delete local group?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Local Group", role: .destructive) {
                Task { await model.resetLocal(using: appState, dismiss: { dismiss() }) }
            }
        } message: {
            Text("Stop recovery loops in a broken group by deleting its local history, state, and draft. Downloaded media caches are also cleared. Other members are unaffected. Rejoining requires a fresh invitation from someone still in the group.")
        }
        .sheet(
            isPresented: $model.showTranscriptShareSheet,
            onDismiss: model.cleanupTranscriptExportFile
        ) {
            if let transcriptExportURL = model.transcriptExportURL {
                ActivityShareSheet(
                    items: [transcriptExportURL],
                    onComplete: model.cleanupTranscriptExportFile
                )
            }
        }
    }

    private var resetSection: some View {
        Section {
            Button("Delete Local Group", role: .destructive) { showResetConfirmation = true }
                .disabled(!appState.developerMode || model.membershipActionInFlight || model.isExportingTranscript)
        } footer: {
            Text("Stop recovery loops in a broken group by deleting its local history, state, and draft. Downloaded media caches are also cleared. Other members are unaffected. Rejoining requires a fresh invitation from someone still in the group.")
        }
    }

    private var conversationSection: some View {
        Section("Conversation") {
            LabeledContent(
                "State",
                value: ChatDeveloperToolsPresentation.lifecycleLabel(
                    membership: conversation.group.selfMembership,
                    leaveRequestPending: conversation.group.leaveRequestPending,
                    isDisbanding: conversation.isGroupDisbanding,
                    isDisbanded: conversation.isGroupDisbanded
                )
            )
            copyableValue(
                "MLS Group ID",
                value: model.mlsState?.groupIdHex ?? conversation.group.groupIdHex
            )
            copyableValue("Nostr Group ID", value: conversation.group.nostrGroupIdHex)

            if let mlsState = model.mlsState {
                LabeledContent("Epoch", value: LocalizedNumberLabel.decimal(mlsState.epoch))
                LabeledContent(
                    "MLS Members",
                    value: LocalizedNumberLabel.decimal(UInt64(mlsState.memberCount))
                )
                DisclosureGroup("Required Components") {
                    ForEach(mlsState.requiredAppComponents, id: \.self) { component in
                        Text(String(component))
                            .font(.body.monospaced())
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading MLS state…").foregroundStyle(.secondary)
                }
            }
            LabeledContent(
                "Admins",
                value: LocalizedNumberLabel.decimal(UInt64(conversation.group.admins.count))
            )
        }
    }

    private var deliverySection: some View {
        Section("Delivery & Notifications") {
            statusRow(
                "Chat Relays",
                value: LocalizedNumberLabel.decimal(UInt64(conversation.group.relays.count)),
                isWarning: conversation.group.relays.isEmpty
            )
            LabeledContent("Notifications", value: notificationLabel)

            if let info = model.pushDebugInfo {
                statusRow(
                    "Local Push",
                    value: info.localRegistration.registered
                        ? L10n.string("Registered")
                        : L10n.string("Not registered"),
                    isWarning: !info.localRegistration.registered
                )
                LabeledContent("Tokens") {
                    Text(GroupPushDebugPresentation.tokenSummary(for: info))
                        .monospacedDigit()
                }
                statusRow(
                    "Relay Hints",
                    value: GroupPushDebugPresentation.missingRelayHintSummary(for: info),
                    isWarning: info.missingRelayHintCount > 0
                )
                LabeledContent("Registration") {
                    Text(GroupPushDebugPresentation.localRegistrationSummary(for: info.localRegistration))
                        .foregroundStyle(.secondary)
                }
                if let leafIndex = info.localRegistration.localLeafIndex {
                    LabeledContent("Local Leaf", value: LocalizedNumberLabel.decimal(UInt64(leafIndex)))
                }
                if let updatedAtMs = info.lastTokenListUpdatedAtMs {
                    LabeledContent("Last Token List Update") {
                        Text(Date(timeIntervalSince1970: TimeInterval(updatedAtMs) / 1000), style: .relative)
                    }
                }
                if !info.tokens.isEmpty {
                    DisclosureGroup("Token Fingerprints") {
                        ForEach(Array(info.tokens.enumerated()), id: \.offset) { _, token in
                            tokenRow(token)
                        }
                    }
                }
            } else if let error = model.pushDebugError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading push notification state…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var diagnosticsSection: some View {
        Section {
            Button {
                Task { await model.exportConversationTranscript(using: appState) }
            } label: {
                HStack {
                    Label("Export Conversation Transcript", systemImage: "doc.text")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if model.isExportingTranscript { ProgressView() }
                }
            }
            .disabled(model.isExportingTranscript || appState.activeAccountRef == nil)
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Exports the raw inner Nostr event history for this group as protected JSON, ordered by time.")
        }
    }

    @ViewBuilder
    private var maintenanceSection: some View {
        Section("Maintenance") {
            if let status = model.maintenanceStatus {
                statusRow(
                    "Worker",
                    value: status.paused ? L10n.string("Paused") : L10n.string("Running"),
                    isWarning: status.paused
                )
                LabeledContent(
                    "Periodic rotation",
                    value: status.periodicEnrolled ? L10n.string("Enrolled") : L10n.string("Not enrolled")
                )
                let overdueCount = status.obligations.lazy.filter(\.overdue).count
                statusRow(
                    "Obligations",
                    value: "\(status.obligations.count) total, \(overdueCount) overdue",
                    isWarning: overdueCount > 0
                )
                let failedFanouts = status.fanouts.reduce(UInt64.zero) { partial, fanout in
                    let (sum, overflow) = partial.addingReportingOverflow(
                        UInt64(fanout.attemptedFailed)
                    )
                    return overflow ? UInt64.max : sum
                }
                statusRow(
                    "Fanouts",
                    value: "\(status.fanouts.count) records, \(failedFanouts) failed targets",
                    isWarning: failedFanouts > 0
                )
                LabeledContent(
                    "Evolutions",
                    value: LocalizedNumberLabel.decimal(UInt64(status.evolutions.count))
                )
                if let nextRotation = MaintenanceDiagnosticsPresentation.date(
                    status.nextPeriodicRotationAt
                ) {
                    LabeledContent("Next rotation") {
                        Text(nextRotation, style: .relative)
                    }
                }

                if !status.obligations.isEmpty {
                    DisclosureGroup("Maintenance obligations") {
                        ForEach(status.obligations, id: \.idHex) { obligation in
                            obligationRow(obligation)
                        }
                    }
                }
                if !status.evolutions.isEmpty {
                    DisclosureGroup("Group evolutions") {
                        ForEach(status.evolutions, id: \.idHex) { evolution in
                            evolutionRow(evolution)
                        }
                    }
                }
                if !status.fanouts.isEmpty {
                    DisclosureGroup("Transport fanouts") {
                        ForEach(status.fanouts, id: \.idHex) { fanout in
                            fanoutRow(fanout)
                        }
                    }
                }
            } else if let error = model.maintenanceStatusError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading maintenance state…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var notificationLabel: String {
        switch model.notifyMode {
        case .all: return L10n.string("All messages")
        case .mentionsOnly: return L10n.string("Mentions only")
        case .nothing: return L10n.string("Off")
        }
    }

    private func statusRow(_ title: String, value: String, isWarning: Bool) -> some View {
        LabeledContent(title) {
            Text(value).foregroundStyle(isWarning ? Color.orange : Color.primary)
        }
    }

    private func copyableValue(_ title: String, value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            Haptics.selection()
            appState.present(.success(L10n.string("Copied to clipboard"), message: title))
        } label: {
            LabeledContent(title) {
                HStack(spacing: 6) {
                    Text(IdentityFormatter.short(value, head: 12, tail: 6))
                        .font(.caption.monospaced())
                    Image(systemName: "doc.on.doc")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.formatted("Copy %@", title))
        .accessibilityValue(value)
    }

    private func tokenRow(_ token: GroupPushTokenDebugEntryFfi) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(GroupPushDebugPresentation.platformLabel(token.platform))
                    .font(.caption.weight(.semibold))
                Text(L10n.formatted(
                    "leaf %@",
                    LocalizedNumberLabel.decimal(UInt64(token.leafIndex))
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if token.isLocalMember {
                    Text("local").font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                }
                if !token.activeLeaf {
                    Text("stale").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            Text(token.tokenFingerprint)
                .font(.caption2.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }

    private func obligationRow(_ obligation: MaintenanceObligationFfi) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(IdentityFormatter.short(obligation.idHex))
                    .font(.caption.monospaced())
                Spacer()
                Text(MaintenanceDiagnosticsPresentation.phaseLabel(obligation.phase))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(obligation.overdue ? Color.orange : Color.secondary)
            }
            Text("\(MaintenanceDiagnosticsPresentation.triggerLabel(obligation.trigger)); \(obligation.attemptCount) attempts; \(obligation.semanticRearmCount) rearms")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let failure = MaintenanceDiagnosticsPresentation.failureCode(
                obligation.lastFailureCode
            ) {
                Text("Last failure: \(failure)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private func evolutionRow(_ evolution: GroupEvolutionStatusFfi) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(IdentityFormatter.short(evolution.idHex))
                    .font(.caption.monospaced())
                Spacer()
                Text(MaintenanceDiagnosticsPresentation.evolutionPhaseLabel(evolution.phase))
                    .font(.caption.weight(.semibold))
            }
            Text("epoch \(evolution.sourceEpoch) → \(evolution.targetEpoch)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func fanoutRow(_ fanout: TransportFanoutStatusFfi) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(IdentityFormatter.short(fanout.idHex))
                    .font(.caption.monospaced())
                Spacer()
                Text(fanout.evolutionConfirmed ? "Confirmed" : "Pending")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(fanout.evolutionConfirmed ? Color.green : Color.secondary)
            }
            Text("accepted \(fanout.accepted)/\(fanout.requiredAcks) required; \(fanout.unattempted) unattempted; \(fanout.attemptedFailed) failed; \(fanout.policyProhibited) prohibited")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(fanout.attemptedFailed > 0 ? Color.orange : Color.secondary)
        }
        .padding(.vertical, 2)
    }
}

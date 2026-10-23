import SwiftUI

/// A completed operation's snapshot. The removed account is never queried here.
struct WipeOutcomeReportView: View {
    let report: WipeReport
    let onClose: () -> Void
    @State private var selectedFailures: WipeOutcomeFailureList?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    EmptyView()
                } header: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(report.hasCleanupIssues ? "Some cleanup couldn’t finish" : "Couldn’t refresh profiles")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Color.primary)
                        Text(report.hasCleanupIssues
                             ? "Review what was removed and what may remain."
                             : "You’ve signed out, but the profile list couldn’t be refreshed.")
                            .font(.body)
                            .foregroundStyle(Color.secondary)
                    }
                    .textCase(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }

                ForEach(report.stages, id: \.stage) { stage in
                    WipeOutcomeStageSection(stage: stage, didWipeData: report.didWipeData) {
                        selectedFailures = $0
                    }
                }
            }
            .navigationTitle("Cleanup Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        // Keep the presenter outside List's recycled sections so opening a
        // nested sheet cannot remove its own presentation host.
        .sheet(item: $selectedFailures) { selection in
            WipeOutcomeFailuresView(title: selection.title, failures: selection.failures)
                .appAppearance()
        }
    }
}

private struct WipeOutcomeFailureList: Identifiable {
    let id: WipeStage
    let title: LocalizedStringKey
    let failures: [WipeFailureItem]
}

private struct WipeOutcomeStageSection: View {
    let stage: WipeStageReport
    let didWipeData: Bool
    let onShowAll: (WipeOutcomeFailureList) -> Void

    private var visibleFailures: ArraySlice<WipeFailureItem> {
        stage.failures.prefix(3)
    }

    private var title: LocalizedStringKey {
        switch stage.stage {
        case .leavingGroups: "Groups"
        case .deletingKeyPackages: "Key Packages"
        case .wipingLocalData: "On This Device"
        }
    }

    private var summary: String {
        switch stage.stage {
        case .leavingGroups:
            L10n.plural("%lld groups left", Int64(stage.completedCount ?? 0))
        case .deletingKeyPackages:
            L10n.plural("%lld key packages deleted", Int64(stage.completedCount ?? 0))
        case .wipingLocalData:
            !didWipeData ? L10n.string("Local data kept on this device")
                : stage.hasCleanupIssues ? L10n.string("Local data cleanup incomplete")
                : L10n.string("Local data wiped")
        }
    }

    private var explanation: String? {
        guard stage.hasIssues else { return nil }
        switch stage.stage {
        case .leavingGroups: return L10n.string("Some groups couldn’t be left.")
        case .deletingKeyPackages: return L10n.string("Some key packages couldn’t be removed from relays.")
        case .wipingLocalData:
            return stage.hasCleanupIssues ? L10n.string("Some profile data may remain on this device.") : nil
        }
    }

    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary)
                    if let explanation {
                        Text(explanation).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: stage.hasCleanupIssues ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(stage.hasCleanupIssues ? Color.orange : Color.green)
            }

            ForEach(Array(visibleFailures.enumerated()), id: \.offset) { _, failure in
                WipeOutcomeFailureRow(failure: failure)
            }

            if stage.failures.count > 3 {
                Button {
                    onShowAll(WipeOutcomeFailureList(id: stage.stage, title: title, failures: stage.failures))
                } label: {
                    HStack {
                        Text(L10n.plural("Show %lld More", Int64(stage.failures.count - 3)))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text(title).wnSectionHeader()
        }
    }
}

private struct WipeOutcomeFailureRow: View {
    let failure: WipeFailureItem

    private var explanation: String? {
        switch failure.kind {
        case .cleanup: nil
        case .notificationPreviews: L10n.string("Some notification previews may remain on this device.")
        case .decryptedMedia: L10n.string("Some decrypted media may remain on this device.")
        case .accountRefresh: L10n.string("The profile list couldn’t be refreshed.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let explanation { Text(explanation).font(.subheadline) }
            if let subject = failure.subject {
                Text(subject).font(.footnote.monospaced()).foregroundStyle(.secondary)
            }
            if !failure.reason.isEmpty {
                if explanation == nil || failure.kind == .accountRefresh {
                    Text(failure.reason).font(.footnote).foregroundStyle(.secondary)
                }
            } else if explanation == nil {
                Text("No additional details are available.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct WipeOutcomeFailuresView: View {
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    let failures: [WipeFailureItem]

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                    WipeOutcomeFailureRow(failure: failure)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

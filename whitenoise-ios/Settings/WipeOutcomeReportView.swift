import SwiftUI

/// Shows the mapped outcome without accessing the wiped account or runtime.
/// RootView keeps this report in the account-exit sheet, above Welcome or
/// the remaining-profile chooser after account routing changes.
struct WipeOutcomeReportView: View {
    let report: WipeReport
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(report.stages, id: \.stage) { stage in
                    Section {
                        stageSummary(stage)
                        ForEach(Array(stage.failures.enumerated()), id: \.offset) { _, failure in
                            failureRow(failure)
                        }
                    }
                }
            }
            .localizedNavigationTitle("Some cleanup couldn’t be completed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
    }

    @ViewBuilder
    private func stageSummary(_ stage: WipeStageReport) -> some View {
        let icon = stage.hasIssues ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        let tint: Color = stage.hasIssues ? .orange : .green
        switch stage.stage {
        case .leavingGroups:
            LabeledContent {
                Text(stage.completedCount ?? 0, format: .number)
                    .foregroundStyle(.secondary)
            } label: {
                Label { Text("Groups left") } icon: {
                    Image(systemName: icon).foregroundStyle(tint)
                }
            }
        case .deletingKeyPackages:
            LabeledContent {
                Text(stage.completedCount ?? 0, format: .number)
                    .foregroundStyle(.secondary)
            } label: {
                Label { Text("Key packages deleted") } icon: {
                    Image(systemName: icon).foregroundStyle(tint)
                }
            }
        case .wipingLocalData:
            Label {
                Text(stage.hasIssues ? "Local data wipe incomplete" : "Local data wiped")
            } icon: {
                Image(systemName: icon).foregroundStyle(tint)
            }
        }
    }

    private func failureRow(_ failure: WipeFailureItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let subject = failure.subject {
                Text(subject)
                    .font(.footnote.monospaced())
            }
            Text(failure.reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

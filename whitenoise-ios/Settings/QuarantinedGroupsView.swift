import SwiftUI
import MarmotKit

struct QuarantinedGroupsView: View {
    @Environment(AppState.self) private var appState

    let model: QuarantinedGroupsViewModel

    var body: some View {
        Form {
            if model.isLoading && model.groups.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading quarantined groups")
                        Spacer()
                    }
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                }
            } else if model.groups.isEmpty && model.loadError == nil {
                Section {
                    ContentUnavailableView(
                        "No Quarantined Groups",
                        systemImage: "checkmark.shield",
                        description: Text("Every stored group for this profile hydrated successfully.")
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section("Groups") {
                    ForEach(model.groups, id: \.groupIdHex) { group in
                        groupRow(group)
                    }
                }
            }

            Section {
                Text("Marmot quarantines a stored group when it cannot safely hydrate its MLS state. Retrying is non-destructive: it does not delete history, bypass validation, or rejoin the group.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let loadError = model.loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Retry Loading") {
                        Task { await model.reload(using: appState) }
                    }
                } header: {
                    Text("Load Failed")
                }
            }
        }
        .localizedNavigationTitle("Quarantined Groups")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.isLoading && !model.groups.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: appState.activeAccountRef) {
            await model.reload(using: appState)
        }
        .refreshable {
            await model.reload(using: appState)
        }
    }

    @ViewBuilder
    private func groupRow(_ group: AppQuarantinedGroupFfi) -> some View {
        let presentation = QuarantinedGroupPresentation.reason(group.reason)
        let isRetrying = model.retryingGroupIds.contains(group.groupIdHex)

        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Group ID") {
                Text(IdentityFormatter.short(group.groupIdHex))
                    .font(.system(.callout, design: .monospaced))
            }

            Label(presentation.title, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)

            Text(presentation.guidance)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let retryStatus = model.retryStatusByGroupId[group.groupIdHex] {
                retryStatusView(retryStatus)
            }

            if presentation.allowsRetry {
                Button {
                    Task { await model.retry(group, using: appState) }
                } label: {
                    if isRetrying {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Retrying Recovery…")
                        }
                    } else {
                        Label("Retry Recovery", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRetrying || appState.activeAccountRef == nil)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func retryStatusView(_ status: QuarantinedGroupsViewModel.RetryStatus) -> some View {
        switch status {
        case .stillQuarantined:
            Label(
                "Recovery did not succeed. The group remains quarantined.",
                systemImage: "xmark.circle"
            )
            .foregroundStyle(.orange)
            .font(.caption)
        case let .failed(diagnostic):
            VStack(alignment: .leading, spacing: 2) {
                Label("Recovery retry failed", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(diagnostic)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }
}

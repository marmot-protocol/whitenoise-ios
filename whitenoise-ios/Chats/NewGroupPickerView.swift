import SwiftUI
import MarmotKit

/// Step one of New Group: searchable multi-select over known people, with a
/// removable rail of the current selection. The selection is owned by the
/// flow model, so navigating to setup and back preserves it.
struct NewGroupPickerView: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: NewChatFlowViewModel
    let onScan: () -> Void
    let onCancel: () -> Void
    let onNext: () -> Void

    var body: some View {
        @Bindable var query = model.groupQuery
        List {
            Section {
                RecipientSearchField(text: $query.text, onScan: onScan)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
                    .listRowBackground(Color.clear)
            }

            if !model.groupSelection.isEmpty {
                Section {
                    SelectedRecipientRail(members: model.groupSelection.members) { member in
                        model.groupSelection.remove(accountIdHex: member.accountIdHex)
                    }
                    .listRowInsets(EdgeInsets())
                }
            }

            switch RecipientQueryMode.mode(
                isBlank: query.isBlank,
                isIdentifierQuery: query.isIdentifierQuery
            ) {
            case .browse, .search:
                peopleSection
                RecipientUserSearchStatus(
                    isSearching: model.groupUserSearch.isSearching,
                    isIncomplete: model.groupUserSearch.isIncomplete,
                    didFail: model.groupUserSearch.didFail,
                    onRetry: { model.groupUserSearch.retry(using: appState) }
                )
            case .resolve:
                RecipientResolutionSection(
                    query: model.groupQuery,
                    excludedAccountIds: model.excludedAccountIds(using: appState),
                    isBusy: model.isBusy,
                    selectedAccountIds: selectedAccountIds,
                    onRetry: { model.groupQuery.queryChanged(using: appState) },
                    onSelect: { resolved in
                        Task { await model.selectResolved(resolved, using: appState) }
                    }
                )
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
                    .disabled(model.isBusy)
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("New Group")
                        .font(.headline)
                    Text(L10n.plural("%lld selected", Int64(model.groupSelection.count)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Continue", action: onNext)
                    .disabled(model.isBusy || appState.activeAccountRef == nil)
            }
        }
        .task {
            await model.directory.load(using: appState)
            updateUserSearch()
        }
        .onChange(of: model.groupQuery.text) { _, _ in
            model.groupQuery.queryChanged(using: appState)
            updateUserSearch()
        }
        .onChange(of: model.groupQuery.resolution) { _, resolution in
            guard case .resolved(let resolved) = resolution else { return }
            Task { await autoSelect(resolved) }
        }
        .onChange(of: appState.profileRefreshGeneration) { _, _ in
            model.directory.refreshSearchFields(using: appState)
        }
        .onDisappear {
            model.groupUserSearch.cancel()
        }
    }

    private var selectedAccountIds: Set<String> {
        Set(model.groupSelection.members.map { $0.accountIdHex.lowercased() })
    }

    private var peopleSection: some View {
        let candidates = browseResults
        return RecipientPeopleSection(
            state: .resolve(
                candidateCount: candidates.count,
                isLoadingDirectory: model.directory.isLoading,
                directoryLoadError: model.directory.loadError,
                isSearchingNetwork: model.groupUserSearch.isSearching,
                trimmedQuery: model.groupQuery.trimmedText
            ),
            candidates: candidates,
            header: model.groupQuery.isBlank ? "People" : nil,
            emptyDescription: "Paste an npub or scan a QR code to add someone you haven't chatted with yet.",
            onRetryLoad: {
                Task { await model.directory.load(using: appState, force: true) }
            },
            row: memberRow
        )
    }

    private var browseResults: [RecipientCandidate] {
        let known = RecipientSearch.browse(
            model.directory.candidates,
            query: model.groupQuery.text,
            excludedAccountIds: model.excludedAccountIds(using: appState),
            fields: { model.directory.matchFields(for: $0) }
        )
        return RecipientSearch.merge(
            known: known,
            discovered: model.groupUserSearch.candidates,
            excludedAccountIds: model.excludedAccountIds(using: appState)
        )
    }

    private func memberRow(_ candidate: RecipientCandidate) -> some View {
        let isSelected = model.groupSelection.isSelected(accountIdHex: candidate.accountIdHex)
        return Button {
            model.toggleSelection(of: candidate, using: appState)
        } label: {
            RecipientRow(
                accountIdHex: candidate.accountIdHex,
                profileOverride: candidate.searchProfile,
                searchContext: RecipientSearch.resultContext(
                    for: candidate,
                    query: model.groupQuery.text
                )
            ) {
                RecipientSelectionIndicator(isSelected: isSelected)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func autoSelect(_ resolved: ResolvedRecipient) async {
        guard NewChatFlowViewModel.shouldAutoSelectResolved(
            accountIdHex: resolved.accountIdHex,
            isBusy: model.isBusy,
            excludedAccountIds: model.excludedAccountIds(using: appState),
            selectedAccountIds: selectedAccountIds
        ) else { return }
        await model.selectResolved(resolved, using: appState)
    }

    private func updateUserSearch() {
        model.groupUserSearch.update(
            query: model.groupQuery.text,
            isIdentifierQuery: model.groupQuery.isIdentifierQuery,
            using: appState
        )
    }
}

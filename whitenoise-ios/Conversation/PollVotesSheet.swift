import SwiftUI
import MarmotKit

/// Per-voter results for one poll. Reads MDK's `pollVotes` pages and re-reads
/// from the first page whenever the poll row is reprojected.
struct PollVotesSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let messageIdHex: String
    let initialOptions: [PollOptionResultFfi]
    let viewModel: ConversationViewModel
    let blockedAccountIds: Set<String>

    @State private var model = PollVotesModel()
    @State private var retryCount = 0

    private struct LoadKey: Hashable {
        let subject: PollVotesSubject?
        let reprojection: UInt64
        let invalidation: UInt64
        let runtimeGeneration: Int
        let runtimeReady: Bool
        let retry: Int
    }

    private var watch: PollVotesWatch? {
        guard let accountIdHex = appState.activeAccount?.accountIdHex, !messageIdHex.isEmpty else { return nil }
        return PollVotesWatch(accountIdHex: accountIdHex, groupIdHex: viewModel.group.groupIdHex,
                              pollEventId: messageIdHex)
    }

    var body: some View {
        let subject = viewModel.pollVotesSubject(for: messageIdHex)
        let watch = watch
        NavigationStack {
            PollVotesList(
                content: content(for: subject),
                locale: AppLanguage.currentLocale,
                displayName: displayName(for:),
                avatar: { voter, name in avatar(for: voter, name: name) },
                onRetry: { retryCount += 1 }
            )
            .navigationTitle("Votes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: watch, initial: true) { previous, current in
            if let previous, previous != current { appState.pollVotesInvalidation.end(previous) }
            if let current { appState.pollVotesInvalidation.begin(current) }
        }
        .onDisappear {
            if let watch { appState.pollVotesInvalidation.end(watch) }
        }
        // Window reprojections cover changed rows; runtime projection events
        // also cover same-tally re-votes the window deduplicates.
        .task(id: LoadKey(
            subject: subject,
            reprojection: viewModel.pollReprojectionRevision(for: messageIdHex),
            invalidation: appState.pollVotesInvalidation.revision,
            runtimeGeneration: appState.runtimeGeneration,
            runtimeReady: appState.canUseRuntimeForForegroundWork,
            retry: retryCount
        )) {
            guard let subject, appState.canUseRuntimeForForegroundWork,
                  let client = try? appState.currentMarmotClient() else { return }
            await model.load(subject, using: client)
        }
    }

    private func content(for subject: PollVotesSubject?) -> PollVotesPresentation.Content {
        // Votes loaded for another account or poll are never shown.
        let isCurrent = subject != nil && model.subject == subject
        let options = viewModel.poll(for: messageIdHex)?.options ?? initialOptions
        let sections = PollVotesPresentation.sections(
            options: options,
            votes: isCurrent ? model.votes : [],
            blockedAccountIds: blockedAccountIds,
            myAccountIdHex: viewModel.myAccountId
        )
        return PollVotesPresentation.content(
            isPollAvailable: !viewModel.isDeleted(messageIdHex),
            phase: isCurrent ? model.phase : .idle,
            sections: sections
        )
    }

    /// Voters outside the loaded window have no conversation identity, so
    /// they resolve through the profile directory like group members do.
    private func displayName(for voter: PollVotesPresentation.Voter) -> String {
        if viewModel.windowIdentities[voter.accountIdHex] != nil {
            return viewModel.windowDisplayName(for: voter.accountIdHex)
        }
        return appState.displayName(forAccountIdHex: voter.accountIdHex)
    }

    @ViewBuilder
    private func avatar(for voter: PollVotesPresentation.Voter, name: String) -> some View {
        switch PollVotesPresentation.avatarSource(
            for: voter, identity: viewModel.windowIdentities[voter.accountIdHex]
        ) {
        case .native(let asset):
            NativeAvatarBubble(seed: voter.accountIdHex, title: name, asset: asset)
        case .monogram:
            AvatarBubble(seed: voter.accountIdHex, title: name)
        }
    }
}

/// Renders a prepared View votes state; owns no loading.
struct PollVotesList<Avatar: View>: View {
    let content: PollVotesPresentation.Content
    let locale: Locale
    let displayName: (PollVotesPresentation.Voter) -> String
    @ViewBuilder let avatar: (PollVotesPresentation.Voter, String) -> Avatar
    let onRetry: () -> Void

    var body: some View {
        List {
            Section {
                Label {
                    Text("Votes aren’t anonymous. Every group member can see who voted for each option.")
                } icon: {
                    Image(systemName: "eye")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            switch content {
            case .loading:
                statusRow {
                    ProgressView(L10n.string("Loading…"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            case .failed(let message):
                statusRow {
                    ContentUnavailableView {
                        Label("Couldn’t load votes", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Retry", action: onRetry)
                    }
                }
            case .unavailable:
                statusRow {
                    ContentUnavailableView {
                        Label("Poll unavailable", systemImage: "chart.bar.xaxis")
                    } description: {
                        Text("This poll was deleted or is no longer available.")
                    }
                }
            case .noVotes:
                statusRow {
                    ContentUnavailableView {
                        Label("No votes yet", systemImage: "chart.bar.xaxis")
                    }
                }
            case .votes(let sections):
                ForEach(sections) { section in
                    optionSection(section)
                }
            }
        }
    }

    private func statusRow<Status: View>(@ViewBuilder _ status: () -> Status) -> some View {
        Section {
            status()
                .listRowBackground(Color.clear)
        }
    }

    private func optionSection(_ section: PollVotesPresentation.OptionSection) -> some View {
        Section {
            if section.voters.isEmpty {
                Text("No votes")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(section.voters) { voter in
                    voterRow(voter)
                }
            }
        } header: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(section.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(L10n.plural("%lld votes", Int64(section.voters.count)))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .textCase(nil)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }

    private func voterRow(_ voter: PollVotesPresentation.Voter) -> some View {
        let name = displayName(voter)
        return HStack(spacing: 12) {
            avatar(voter, name)
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.body.weight(.medium))
                    if voter.isMe {
                        Text("You")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.18), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                }
                if voter.isBlocked {
                    // Not a Label: List rows give Label icons a wide fixed column.
                    HStack(spacing: 4) {
                        Image(systemName: "nosign")
                            .accessibilityHidden(true)
                        Text("Blocked")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let votedAt = PollVotesPresentation.votedAtLabel(voter.votedAt, locale: locale) {
                    Text(L10n.formatted("Voted %@", votedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Poll votes") {
    let me = String(repeating: "a", count: 64)
    let blocked = String(repeating: "b", count: 64)
    let peer = String(repeating: "c", count: 64)
    let sections = PollVotesPresentation.sections(
        options: [
            PollOptionResultFfi(id: "0", label: "Thai", votes: 2),
            PollOptionResultFfi(id: "1", label: "Pizza", votes: 1),
            PollOptionResultFfi(id: "2", label: "Salad", votes: 0)
        ],
        votes: [
            PollVoteFfi(voterAccountIdHex: me, optionIds: ["0"], votedAt: 1_790_000_000),
            PollVoteFfi(voterAccountIdHex: blocked, optionIds: ["0", "1"], votedAt: 1_790_000_600)
        ],
        blockedAccountIds: [blocked],
        myAccountIdHex: me
    )
    let names = [me: "Jeff", blocked: "Mallory", peer: "Alice"]
    return PollVotesList(
        content: .votes(sections),
        locale: Locale(identifier: "en_US"),
        displayName: { names[$0.accountIdHex] ?? "Unknown" },
        avatar: { voter, name in AvatarBubble(seed: voter.accountIdHex, title: name) },
        onRetry: {}
    )
}

import SwiftUI
import MarmotKit

struct GroupRecoveryView: View {
    @Environment(AppState.self) private var appState
    let model: GroupRecoveryModel
    let groupID: String
    let onRejoined: () async -> Void
    @State private var selection: RejoinSelection?

    private struct RejoinSelection: Identifiable {
        let id = UUID()
        let offer: GroupRejoinInvitationFfi
        let authorName: String
        let authorIdentity: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.syncParked {
                GroupSyncParkedBanner(isRetrying: model.isRetryingSync, error: model.syncRetryError) {
                    Task { await model.retrySync(using: appState, groupID: groupID) }
                }
            }
            if !model.refusedRelays.isEmpty {
                GroupCommitRefusalBanner(
                    message: GroupCommitRefusalPresentation.message(for: model.refusedRelays),
                    isDismissing: model.isDismissingRefusal,
                    error: model.refusalDismissError
                ) {
                    Task { await model.dismissRefusal(using: appState, groupID: groupID) }
                }
            }
            if let status = model.status {
                if status.historyMayBeIncomplete, !status.historyNoticeIds.isEmpty {
                    HistoryNoticeBanner(
                        message: HistoryNoticePresentation.groupMessage(
                            noticeIDs: status.historyNoticeIds,
                            notices: appState.historyNotices.notices
                        ),
                        isDismissing: !appState.historyNotices.dismissing.isDisjoint(with: status.historyNoticeIds)
                    ) {
                        Task {
                            _ = await appState.historyNotices.dismiss(status.historyNoticeIds, using: appState)
                            await model.refresh(using: appState, groupID: groupID)
                        }
                    }
                }
                if status.automaticRecoveryFailed {
                    Label("Unable to restore group synchronization.", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                        .foregroundStyle(.orange)
                }
                if status.pendingReinvites > 0 {
                    Text("Some invitations are being retried automatically.")
                }
                if status.failedReinvites > 0 {
                    Text("Some invitations could not be restored. Invite those people again from Group Details.")
                        .foregroundStyle(.orange)
                }
                ForEach(status.rejoinInvitations, id: \.welcomeIdHex) { offer in
                    Button {
                        selection = RejoinSelection(
                            offer: offer,
                            authorName: appState.displayName(forAccountIdHex: offer.welcomerAccountIdHex),
                            authorIdentity: (try? appState.currentMarmotClient())?.npub(accountIdHex: offer.welcomerAccountIdHex)
                                ?? offer.welcomerAccountIdHex
                        )
                    } label: {
                        Label("Review Rejoin Invitation", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.secondary)
                Button("Retry") { Task { await model.refresh(using: appState, groupID: groupID) } }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(GroupRecoveryModel.hasContent(
            status: model.status, errorMessage: model.errorMessage, syncParked: model.syncParked,
            hasCommitRefusal: !model.refusedRelays.isEmpty
        ) ? 12 : 0)
        .onChange(of: appState.activeAccountRef) { selection = nil }
        .onChange(of: appState.runtimeGeneration) { selection = nil }
        .sheet(item: $selection) { selected in
            NavigationStack {
                Form {
                    Section("Invited by") {
                        Text(selected.authorName)
                        Text(selected.authorIdentity)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    Section {
                        Text("Rejoining replaces this device’s current group state with the invited copy. Your saved message history is kept.")
                        Text("Only rejoin if you trust this invitation. A newer group version alone does not make it trustworthy.")
                    }
                    Section {
                        Button("Rejoin Group") {
                            Task {
                                let succeeded = await model.decide(selected.offer, confirm: true, using: appState)
                                selection = nil
                                if succeeded { await onRejoined() }
                            }
                        }
                        Button("Decline Invitation", role: .destructive) {
                            Task {
                                _ = await model.decide(selected.offer, confirm: false, using: appState)
                                selection = nil
                            }
                        }
                    }
                    .disabled(model.isBusy)
                }
                .navigationTitle("Rejoin Group?")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { selection = nil }.disabled(model.isBusy)
                    }
                }
                .interactiveDismissDisabled(model.isBusy)
            }
            .appAppearance()
        }
    }
}

/// A chat whose sync MDK stopped retrying. Sends stay queued until it resumes,
/// either on new activity from another member or an explicit Retry.
struct GroupSyncParkedBanner: View {
    let isRetrying: Bool
    let error: String?
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("This chat stopped syncing")
                    .font(.subheadline.weight(.semibold))
                Text(error ?? L10n.string("Messages you send will wait until it catches up."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: onRetry) {
                if isRetrying {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Retrying"))
                } else {
                    Text("Retry")
                }
            }
            .font(.footnote.weight(.semibold))
            .disabled(isRetrying)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// Wording for relays that refused one of this device's confirmed group
/// changes for good. MDK won't deliver the change there.
nonisolated enum GroupCommitRefusalPresentation {
    static func message(for refused: [GroupCommitRefusedRelayFfi]) -> String {
        let tooLarge = !refused.isEmpty && refused.allSatisfy { $0.cause == .tooLarge }
        if refused.count == 1, let host = AccountSetupRelayFindingPresentation.host(refused[0].relayUrl) {
            return tooLarge
                ? L10n.formatted("%@ refused a group change you made because it was too large. Members who use only that relay may not get it.", host)
                : L10n.formatted("%@ refused a group change you made. Members who use only that relay may not get it.", host)
        }
        let count = Int64(refused.count)
        return tooLarge
            ? L10n.plural("%lld relays refused a group change you made because it was too large. Members who use only those relays may not get it.", count)
            : L10n.plural("%lld relays refused a group change you made. Members who use only those relays may not get it.", count)
    }
}

/// A group relay refused one of this device's confirmed changes for good.
/// Dismissing acknowledges it in MDK, which then allows group changes again.
struct GroupCommitRefusalBanner: View {
    let message: String
    let isDismissing: Bool
    let error: String?
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Group change refused")
                    .font(.subheadline.weight(.semibold))
                Text(error ?? message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                if isDismissing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Dismiss"))
                } else {
                    Text("Dismiss")
                }
            }
            .font(.footnote.weight(.semibold))
            .disabled(isDismissing)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

#Preview("Group change refused") {
    VStack(spacing: 12) {
        GroupCommitRefusalBanner(
            message: "relay.example refused a group change you made because it was too large. Members who use only that relay may not get it.",
            isDismissing: false, error: nil
        ) {}
        GroupCommitRefusalBanner(message: "", isDismissing: true, error: nil) {}
    }
    .padding()
}

#Preview("Stopped syncing") {
    VStack(spacing: 12) {
        GroupSyncParkedBanner(isRetrying: false, error: nil) {}
        GroupSyncParkedBanner(isRetrying: true, error: nil) {}
        GroupSyncParkedBanner(isRetrying: false, error: "Couldn’t retry syncing. Try again.") {}
    }
    .padding()
}

import SwiftUI
import MarmotKit

/// Inline block/unblock control for the surfaces that are already about one
/// person: their profile and a direct chat's info screen.
///
/// The host owns the `BlockedUsersModel` and runs its subscription, because a
/// host may need the same block state to change the rest of its layout and the
/// subscription must outlive this row's visibility.
struct BlockUserActions: View {
    @Environment(AppState.self) private var appState

    let model: BlockedUsersModel
    /// Shown while the live list is still arriving, so the row is never empty.
    var reloadAfterFailure: () -> Void

    private struct PendingIntent {
        let accountRef: String
        let targetId: String
        let blocked: Bool
    }

    @State private var pendingIntent: PendingIntent?

    var body: some View {
        Group {
            if let error = model.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(L10n.string("Retry")) {
                    if let intent = model.uncertainIntent {
                        Task { await model.setBlocked(intent.blocked, userId: intent.id, using: appState) }
                    } else {
                        reloadAfterFailure()
                    }
                }
                .disabled(model.isSaving)
            }

            switch action {
            case .publishing(let isBlocking):
                BlockPublishingRow(isBlocking: isBlocking)
            case .inert(let isBlocked):
                blockToggle(isBlocked: isBlocked, isEnabled: false)
            case .ready(let isBlocked):
                blockToggle(isBlocked: isBlocked, isEnabled: true)
            }
        }
    }

    @ViewBuilder
    private func blockToggle(isBlocked: Bool, isEnabled: Bool) -> some View {
        Button(role: isBlocked ? nil : .destructive) {
            guard let accountRef = appState.activeAccountRef, let targetId = model.targetId else { return }
            pendingIntent = PendingIntent(accountRef: accountRef, targetId: targetId, blocked: !isBlocked)
        } label: {
            Label {
                Text(isBlocked ? L10n.string("Unblock") : L10n.string("Block"))
            } icon: {
                // A destructive role reddens the title but leaves the symbol on
                // the tint, which reads as a blue icon on a red row before
                // iOS 26 colors it.
                Image(systemName: isBlocked ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark")
                    .foregroundStyle(isBlocked ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.red))
            }
        }
        .disabled(!isEnabled)
        .confirmationDialog(
            pendingIntent?.blocked == true
                ? Text("Block this user?")
                : Text("Unblock this user?"),
            isPresented: confirmationPresented,
            titleVisibility: .visible
        ) {
            if let intent = pendingIntent {
                Button(
                    intent.blocked ? L10n.string("Block User") : L10n.string("Unblock User"),
                    role: intent.blocked ? .destructive : nil
                ) {
                    Task {
                        guard appState.activeAccountRef == intent.accountRef,
                              model.targetId == intent.targetId
                        else { return }
                        await model.setBlocked(intent.blocked, userId: intent.targetId, using: appState)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if pendingIntent?.blocked == true {
                Text("Blocking hides this person’s messages and prevents sending to them in direct chats. Existing history is retained.")
            } else {
                Text("Their messages will appear again and you'll be able to send to them.")
            }
        }
    }

    private var action: BlockedUsersPresentation.BlockAction {
        BlockedUsersPresentation.blockAction(
            isLoaded: model.isLoaded,
            publishingIsBlocking: model.targetId.flatMap { model.publishingDirection(for: $0) },
            hasUncertainIntent: model.uncertainIntent != nil,
            isBlocked: model.targetIsBlocked,
            targetAccountIdHex: model.targetId
        )
    }

    private var confirmationPresented: Binding<Bool> {
        Binding {
            pendingIntent != nil
        } set: { isPresented in
            if !isPresented { pendingIntent = nil }
        }
    }
}

/// Replaces the block control while its mutation publishes, so the row says
/// which way it is going instead of going quiet and grey.
struct BlockPublishingRow: View {
    let isBlocking: Bool

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(isBlocking ? L10n.string("Blocking user…") : L10n.string("Unblocking user…"))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

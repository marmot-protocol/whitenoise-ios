import SwiftUI
import MarmotKit

/// Inline block/unblock control for the surfaces that are already about one
/// person: their profile and a direct chat's info screen.
///
/// The host owns the `BlockedUsersModel` and runs its subscription, because a
/// host may need the same block state to change the rest of its layout and the
/// subscription must outlive this row's visibility.
struct BlockUserSection: View {
    @Environment(AppState.self) private var appState

    let model: BlockedUsersModel
    /// Shown while the live list is still arriving, so the row is never empty.
    var reloadAfterFailure: () -> Void

    @State private var pendingIntent: Bool?

    var body: some View {
        Section {
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
        } footer: {
            Text("Blocking hides this person’s messages and prevents sending to them in direct chats. Existing history is retained.")
        }
        .confirmationDialog(
            pendingIntent == true
                ? Text("Block this user?")
                : Text("Unblock this user?"),
            isPresented: confirmationPresented,
            titleVisibility: .visible
        ) {
            if let intent = pendingIntent, let id = model.targetId {
                Button(
                    intent ? L10n.string("Block User") : L10n.string("Unblock User"),
                    role: intent ? .destructive : nil
                ) {
                    Task { await model.setBlocked(intent, userId: id, using: appState) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if pendingIntent == true {
                Text("Blocking hides this person’s messages and prevents sending to them in direct chats. Existing history is retained.")
            } else {
                Text("Their messages will appear again and you'll be able to send to them.")
            }
        }
    }

    @ViewBuilder
    private func blockToggle(isBlocked: Bool, isEnabled: Bool) -> some View {
        Button(role: isBlocked ? nil : .destructive) {
            pendingIntent = !isBlocked
        } label: {
            Label {
                Text(isBlocked ? L10n.string("Unblock User") : L10n.string("Block User"))
            } icon: {
                // A destructive role reddens the title but leaves the symbol on
                // the tint, which reads as a blue icon on a red row before
                // iOS 26 colors it.
                Image(systemName: isBlocked ? "person.crop.circle.badge.checkmark" : "hand.raised")
                    .foregroundStyle(isBlocked ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.red))
            }
        }
        .disabled(!isEnabled)
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

/// The blocked-peer replacement for a profile's action row, mirroring the
/// Flutter client: while someone is blocked the interaction actions are
/// withdrawn and this states why, with the undo attached.
struct BlockedPeerNoticeSection: View {
    @Environment(AppState.self) private var appState

    let model: BlockedUsersModel

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("You blocked this user")
                    .font(.headline)
                Text("You've blocked this user. You won't be able to send messages until you unblock them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

            if let id = model.targetId, model.publishingDirection(for: id) != nil {
                BlockPublishingRow(isBlocking: false)
            } else {
                Button {
                    guard let id = model.targetId else { return }
                    Task { await model.setBlocked(false, userId: id, using: appState) }
                } label: {
                    Label {
                        Text("Unblock User")
                    } icon: {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                    }
                }
                .disabled(!model.canMutate || model.targetId == nil)
            }
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

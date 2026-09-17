import SwiftUI

/// Device-wide list of the active account's blocked people. Rows open the
/// contact's profile, which owns the block/unblock control; the swipe action is
/// the shortcut for undoing one entry without leaving the list.
struct BlockedUsersView: View {
    @Environment(AppState.self) private var appState

    @State private var model = BlockedUsersModel()
    @State private var reload = 0
    @State private var pendingUnblock: BlockedUsersPresentation.Row?

    var body: some View {
        List {
            if let error = model.error {
                Section {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button(L10n.string("Retry")) {
                        if let intent = model.uncertainIntent {
                            Task { await model.setBlocked(intent.blocked, userId: intent.id, using: appState) }
                        } else {
                            reload += 1
                        }
                    }
                    .disabled(model.isSaving)
                }
            }

            if model.isLoaded {
                Section {
                    if rows.isEmpty {
                        Text("No blocked users")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rows) { row in
                        rowView(row)
                    }
                } footer: {
                    Text("Blocking hides this person’s messages and prevents sending to them in direct chats. Existing history is retained.")
                }
            } else if model.error == nil {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .localizedNavigationTitle("Blocked Users")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: subscriptionKey) { await model.run(using: appState, target: nil) }
        .confirmationDialog(
            Text("Unblock this user?"),
            isPresented: unblockConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let pendingUnblock {
                Button(L10n.string("Unblock User")) {
                    Task { await model.setBlocked(false, userId: pendingUnblock.accountIdHex, using: appState) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their messages will appear again and you'll be able to send to them.")
        }
    }

    @ViewBuilder
    private func rowView(_ row: BlockedUsersPresentation.Row) -> some View {
        let isUnblocking = model.publishingDirection(for: row.accountIdHex) != nil
        if let npub = row.npub {
            NavigationLink {
                ProfileContentView(npub: npub).wnBackButton()
            } label: {
                BlockedUserRow(row: row, isUnblocking: isUnblocking)
            }
            .swipeActions(edge: .trailing) { unblockSwipeAction(row) }
        } else {
            BlockedUserRow(row: row, isUnblocking: isUnblocking)
                .swipeActions(edge: .trailing) { unblockSwipeAction(row) }
        }
    }

    @ViewBuilder
    private func unblockSwipeAction(_ row: BlockedUsersPresentation.Row) -> some View {
        Button {
            pendingUnblock = row
        } label: {
            Label("Unblock", systemImage: "person.crop.circle.badge.checkmark")
        }
        .tint(.accentColor)
        .disabled(!model.canMutate)
    }

    private var rows: [BlockedUsersPresentation.Row] {
        BlockedUsersPresentation.rows(
            users: model.users,
            displayName: { appState.displayName(forAccountIdHex: $0) },
            npub: { IdentityPresentation.canonicalNpub(accountIdHex: $0) }
        )
    }

    private var unblockConfirmationPresented: Binding<Bool> {
        Binding {
            pendingUnblock != nil
        } set: { isPresented in
            if !isPresented { pendingUnblock = nil }
        }
    }

    private var subscriptionKey: String {
        "\(appState.activeAccountRef ?? "")/\(appState.runtimeGeneration)/\(appState.canUseRuntimeForForegroundWork)/\(reload)"
    }
}

/// Person row for the blocked list: the same avatar + name + npub shape the
/// group member lists use, so blocked people read as people, not as keys.
struct BlockedUserRow: View {
    @Environment(AppState.self) private var appState
    let row: BlockedUsersPresentation.Row
    var isUnblocking = false

    var body: some View {
        HStack(spacing: 12) {
            AvatarBubble(
                seed: row.accountIdHex,
                title: row.displayName,
                pictureURL: appState.avatarURL(forAccountIdHex: row.accountIdHex)
            )
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName)
                    .font(.body)
                // The swipe action is gone by the time the publish starts, so
                // the row itself has to report what is happening to it.
                if isUnblocking {
                    Text("Unblocking user…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(appState.shortNpub(forAccountIdHex: row.accountIdHex))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
        .task(id: row.accountIdHex) {
            appState.warmProfileProjection(forAccountIdHex: row.accountIdHex)
        }
    }
}

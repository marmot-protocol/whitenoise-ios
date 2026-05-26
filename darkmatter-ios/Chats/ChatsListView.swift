import SwiftUI
import MarmotKit

struct ChatsListView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: ChatsListViewModel?
    @State private var showNewChat = false
    @State private var showSwitcher = false
    @State private var path: [ChatNavigationTarget] = []
    @State private var searchText = ""
    @State private var scope: ChatScope = .active

    enum ChatScope { case active, archived }

    struct ChatNavigationTarget: Hashable {
        let groupIdHex: String
        let messageIdHex: String?

        init(groupIdHex: String, messageIdHex: String? = nil) {
            self.groupIdHex = groupIdHex
            let messageId = messageIdHex?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.messageIdHex = messageId?.isEmpty == false ? messageId : nil
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let viewModel {
                    content(viewModel: viewModel)
                } else {
                    ProgressView()
                }
            }
            // No large "Chats" header — just the toolbar icons, then the list.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    accountSwitcher
                }
                ToolbarItem(placement: .principal) {
                    scopePills
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewChat = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                }
            }
            // Hidden by default; pulling the list down reveals it.
            .searchable(text: $searchText, prompt: "Search chats")
            // Registered at a stable level so navigation works even when the
            // visible list is empty (e.g. just-created or deep-linked chats).
            .navigationDestination(for: ChatNavigationTarget.self) { target in
                if let viewModel {
                    ChatDestination(target: target, viewModel: viewModel)
                }
            }
            .sheet(isPresented: $showNewChat) {
                NewChatSheet()
            }
            .sheet(isPresented: $showSwitcher) {
                AccountSwitcherSheet()
            }
            .task(id: subscriptionScope) {
                // Own both creation and binding here so bind() can't be skipped
                // by a nil viewModel: the lazy-creation task could fire after
                // this one, leaving the list permanently empty and unbound.
                let vm = viewModel ?? ChatsListViewModel(appState: appState)
                if viewModel == nil { viewModel = vm }
                await vm.bind(accountRef: appState.activeAccountRef, force: true)
            }
            .onAppear {
                // Reflect messages we sent from a conversation (which emit no
                // event) when returning to the list.
                Task { await viewModel?.refreshLatest() }
            }
        }
        // Warm path: a chat created / deep-linked while the list is on screen.
        .onChange(of: appState.pendingChatId) { _, _ in consumePendingChat() }
        // Cold path: a deep link that set pendingChatId before this appeared.
        .task { consumePendingChat() }
    }

    /// Navigate into a chat requested via `AppState.pendingChatId`, closing any
    /// presenting sheets (composer, account switcher and its nested QR/profile
    /// sheets) so the pushed conversation lands on top.
    private func consumePendingChat() {
        guard let newId = appState.pendingChatId else { return }
        let target = ChatNavigationTarget(
            groupIdHex: newId,
            messageIdHex: appState.pendingChatMessageIdHex
        )
        showNewChat = false
        showSwitcher = false
        scope = .active
        path = [target]
        appState.clearPendingChat()
    }

    private var subscriptionScope: SubscriptionScope {
        SubscriptionScope(
            accountRef: appState.activeAccountRef,
            runtimeGeneration: appState.runtimeGeneration
        )
    }

    private struct SubscriptionScope: Hashable {
        let accountRef: String?
        let runtimeGeneration: Int
    }

    // MARK: - Active / Archived pills

    private var scopePills: some View {
        HStack(spacing: 6) {
            pill("Active", target: .active)
            pill("Archived", target: .archived)
        }
    }

    private func pill(_ title: String, target: ChatScope) -> some View {
        let selected = scope == target
        return Button {
            scope = target
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(selected ? Color.accentColor : Color(.secondarySystemFill)))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - List

    @ViewBuilder
    private func content(viewModel: ChatsListViewModel) -> some View {
        if viewModel.isLoading && viewModel.items.isEmpty {
            ProgressView()
        } else if let error = viewModel.loadError {
            ContentUnavailableView(
                "Couldn't load chats",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else {
            let rows = currentRows(viewModel)
            List {
                ForEach(rows) { item in
                    // ZStack with a hidden NavigationLink keeps the whole row
                    // tappable while suppressing the default disclosure chevron
                    // (the trailing slot shows the message timestamp instead).
                    ZStack {
                        ChatRow(item: item)
                        NavigationLink(value: ChatNavigationTarget(groupIdHex: item.group.groupIdHex)) { EmptyView() }
                            .opacity(0)
                    }
                    .swipeActions(edge: .trailing) {
                        swipeActions(for: item)
                    }
                    // Drop the separator above the very first row.
                    .listRowSeparator(
                        item.id == rows.first?.id ? .hidden : .automatic,
                        edges: .top
                    )
                }
            }
            .listStyle(.plain)
            .overlay {
                if rows.isEmpty { emptyState }
            }
            .refreshable { await viewModel.refreshLatest() }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if scope == .archived {
            ContentUnavailableView(
                "No archived chats",
                systemImage: "archivebox",
                description: Text("Swipe a chat to archive it; archived chats stay active and still notify you.")
            )
        } else {
            EmptyChatsState(action: { showNewChat = true })
        }
    }

    private func currentRows(_ viewModel: ChatsListViewModel) -> [ChatsListViewModel.Item] {
        let base = scope == .active ? viewModel.items : viewModel.archivedItems
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter { searchHaystack(for: $0).localizedCaseInsensitiveContains(query) }
    }

    private func searchHaystack(for item: ChatsListViewModel.Item) -> String {
        let title = GroupDisplay.title(
            group: item.group,
            otherMember: item.otherMemberAccount,
            memberCount: item.memberCount,
            appState: appState
        )
        let preview = item.latest.map { MessagePreview.body($0) } ?? ""
        return title + " " + preview
    }

    @ViewBuilder
    private func swipeActions(for item: ChatsListViewModel.Item) -> some View {
        if item.group.archived {
            Button {
                Task { await setArchived(group: item.group, archived: false) }
            } label: {
                Label("Unarchive", systemImage: "tray.and.arrow.up")
            }
            .tint(.blue)
            Button(role: .destructive) {
                Task { await leave(group: item.group) }
            } label: {
                Label("Leave", systemImage: "person.crop.circle.badge.minus")
            }
        } else {
            Button(role: .destructive) {
                Task { await leave(group: item.group) }
            } label: {
                Label("Leave", systemImage: "person.crop.circle.badge.minus")
            }
            Button {
                Task { await setArchived(group: item.group, archived: true) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.gray)
        }
    }

    private var accountSwitcher: some View {
        Button {
            showSwitcher = true
        } label: {
            if let active = appState.activeAccount {
                AvatarBubble(
                    seed: active.accountIdHex,
                    title: appState.displayName(forAccountIdHex: active.accountIdHex),
                    pictureURL: appState.avatarURL(forAccountIdHex: active.accountIdHex)
                )
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.18), radius: 2.5, y: 1)
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
        // Plain style so the avatar fills the tap target edge-to-edge instead
        // of sitting inside a glass capsule with padding; the shadow above
        // preserves the raised, tappable affordance.
        .buttonStyle(.plain)
        .accessibilityLabel("Accounts")
    }

    @MainActor
    private func leave(group: AppGroupRecordFfi) async {
        guard let ref = appState.activeAccountRef else { return }
        do {
            _ = try await appState.marmot.leaveGroup(
                accountRef: ref,
                groupIdHex: group.groupIdHex
            )
            Haptics.warning()
        } catch {
            Haptics.error()
            appState.present(.error("Couldn't leave chat", message: error.localizedDescription))
        }
    }

    @MainActor
    private func setArchived(group: AppGroupRecordFfi, archived: Bool) async {
        guard let ref = appState.activeAccountRef else { return }
        do {
            let updated = try appState.marmot.setGroupArchived(
                accountRef: ref,
                groupIdHex: group.groupIdHex,
                archived: archived
            )
            // The chats subscription only fires on transport events, not local
            // projection writes, so reflect the archive change immediately.
            viewModel?.applyLocalGroupChange(updated)
            Haptics.success()
        } catch {
            Haptics.error()
            appState.present(.error("Couldn't archive chat", message: error.localizedDescription))
        }
    }
}

/// Resolves a group id to its conversation. A just-created or deep-linked
/// chat may not be in the list yet, so show a spinner until the chats
/// subscription delivers it — then fall back to an unavailable state if it
/// never arrives (e.g. a link to a chat this account isn't a member of).
private struct ChatDestination: View {
    let target: ChatsListView.ChatNavigationTarget
    let viewModel: ChatsListViewModel
    @State private var timedOut = false

    private var item: ChatsListViewModel.Item? {
        (viewModel.items + viewModel.archivedItems)
            .first(where: { $0.group.groupIdHex == target.groupIdHex })
    }

    var body: some View {
        if let item {
            ConversationView(
                chat: item.group,
                initialOtherMember: item.otherMemberAccount,
                initialMemberCount: item.memberCount,
                initialTargetMessageIdHex: target.messageIdHex
            )
        } else if timedOut {
            ContentUnavailableView("Chat unavailable", systemImage: "questionmark.circle")
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    timedOut = true
                }
        }
    }
}

private struct EmptyChatsState: View {
    let action: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No chats yet", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Start a conversation by inviting someone with their npub.")
                .multilineTextAlignment(.center)
        } actions: {
            Button {
                action()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

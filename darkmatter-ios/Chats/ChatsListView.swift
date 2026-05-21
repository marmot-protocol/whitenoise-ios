import SwiftUI
import MarmotKit

struct ChatsListView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: ChatsListViewModel?
    @State private var showNewChat = false
    @State private var showSwitcher = false

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel: viewModel)
            } else {
                ProgressView()
                    .task { viewModel = ChatsListViewModel(appState: appState) }
            }
        }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                accountSwitcher
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
        .sheet(isPresented: $showNewChat) {
            NewChatSheet()
        }
        .sheet(isPresented: $showSwitcher) {
            AccountSwitcherSheet()
        }
        .task(id: appState.activeAccountRef) {
            await viewModel?.bind(accountRef: appState.activeAccountRef)
        }
        .onAppear {
            // Reflect messages we sent from a conversation (which emit no
            // event) when returning to the list.
            Task { await viewModel?.refreshLatest() }
        }
    }

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
        } else if viewModel.items.isEmpty {
            EmptyChatsState(action: { showNewChat = true })
        } else {
            List {
                ForEach(viewModel.items) { item in
                    // ZStack with a hidden NavigationLink keeps the whole row
                    // tappable while suppressing the default disclosure chevron
                    // (the trailing slot shows the message timestamp instead).
                    ZStack {
                        ChatRow(item: item)
                        NavigationLink(value: item.group.groupIdHex) { EmptyView() }
                            .opacity(0)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await leave(group: item.group) }
                        } label: {
                            Label("Leave", systemImage: "person.crop.circle.badge.minus")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await viewModel.refreshLatest() }
            .navigationDestination(for: String.self) { groupIdHex in
                if let group = viewModel.items.first(where: { $0.group.groupIdHex == groupIdHex })?.group {
                    ConversationView(chat: group)
                } else {
                    ContentUnavailableView("Chat unavailable", systemImage: "questionmark.circle")
                }
            }
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
                .frame(width: 32, height: 32)
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
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

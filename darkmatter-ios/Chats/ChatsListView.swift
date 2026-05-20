import SwiftUI
import MarmotKit

struct ChatsListView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: ChatsListViewModel?
    @State private var showNewChat = false

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
        .task(id: appState.activeAccountRef) {
            await viewModel?.bind(accountRef: appState.activeAccountRef)
        }
    }

    @ViewBuilder
    private func content(viewModel: ChatsListViewModel) -> some View {
        if viewModel.isLoading && viewModel.chats.isEmpty {
            ProgressView()
        } else if let error = viewModel.loadError {
            ContentUnavailableView(
                "Couldn't load chats",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if viewModel.chats.isEmpty {
            EmptyChatsState(action: { showNewChat = true })
        } else {
            List {
                ForEach(viewModel.chats, id: \.groupIdHex) { chat in
                    NavigationLink(value: chat.groupIdHex) {
                        ChatRow(chat: chat)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await leave(chat: chat) }
                        } label: {
                            Label("Leave", systemImage: "person.crop.circle.badge.minus")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationDestination(for: String.self) { groupIdHex in
                if let chat = viewModel.chats.first(where: { $0.groupIdHex == groupIdHex }) {
                    ConversationView(chat: chat)
                } else {
                    ContentUnavailableView("Chat unavailable", systemImage: "questionmark.circle")
                }
            }
        }
    }

    private var accountSwitcher: some View {
        Menu {
            ForEach(appState.accounts, id: \.label) { account in
                Button {
                    appState.activeAccountRef = account.label
                } label: {
                    Label(
                        IdentityFormatter.displayName(
                            label: account.label,
                            accountIdHex: account.accountIdHex
                        ),
                        systemImage: account.label == appState.activeAccountRef
                            ? "checkmark.circle.fill"
                            : "person.crop.circle"
                    )
                }
            }
            Divider()
            NavigationLink {
                AccountsView()
            } label: {
                Label("Manage Accounts", systemImage: "gearshape")
            }
        } label: {
            if let active = appState.activeAccount {
                AvatarBubble(
                    seed: active.accountIdHex,
                    title: IdentityFormatter.displayName(
                        label: active.label,
                        accountIdHex: active.accountIdHex
                    )
                )
                .frame(width: 32, height: 32)
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
    }

    @MainActor
    private func leave(chat: AppGroupRecordFfi) async {
        guard let ref = appState.activeAccountRef else { return }
        do {
            _ = try await appState.marmot.leaveGroup(
                accountRef: ref,
                groupIdHex: chat.groupIdHex
            )
        } catch {
            // Errors surface via the subscription's reconciliation; no UI
            // affordance for transient failures in v1.
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

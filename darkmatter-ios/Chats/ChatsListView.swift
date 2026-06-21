import SwiftUI
import UIKit
import MarmotKit

struct ChatsListView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: ChatsListViewModel?
    @State private var showNewChat = false
    @State private var showSwitcher = false
    @State private var path: [ChatNavigationTarget] = []
    @State private var searchText = ""
    @State private var searchEditing = false
    @State private var scope: ChatScope = .active
    @FocusState private var searchFocused: Bool
    @State private var isKeyboardVisible = false
    @Environment(\.colorScheme) private var colorScheme

    private var hasSearchText: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchCancellationActive: Bool {
        isKeyboardVisible || searchFocused || hasSearchText
    }

    enum ChatScope: CaseIterable, Hashable {
        case active, archived, unread

        var title: LocalizedStringKey {
            switch self {
            case .active: "Active"
            case .archived: "Archived"
            case .unread: "Unread"
            }
        }

        var systemImage: String {
            switch self {
            case .active: "bubble.left.and.bubble.right"
            case .archived: "archivebox"
            case .unread: "circle.fill"
            }
        }
    }

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
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    accountSwitcher
                }
                ToolbarItem(placement: .topBarTrailing) {
                    filterMenu
                }
            }
            .bottomInputChromeAccessory {
                chatListSearchControls
            }
            // Registered at a stable level so navigation works even when the
            // visible list is empty (e.g. just-created or deep-linked chats).
            .navigationDestination(for: ChatNavigationTarget.self) { target in
                if let viewModel {
                    ChatDestination(target: target, viewModel: viewModel, appState: appState)
                }
            }
            .sheet(isPresented: $showNewChat) {
                NewChatSheet()
                    .appAppearance()
            }
            .sheet(isPresented: $showSwitcher) {
                AccountSwitcherSheet()
                    .appAppearance()
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
                Task { await viewModel?.refreshRows() }
            }
            .onChange(of: appState.profileRefreshGeneration) { _, _ in
                viewModel?.refreshDisplayProjections()
            }
            .onChange(of: path.count) { oldCount, count in
                if count > 0 || (oldCount > 0 && count == 0) {
                    dismissSearchKeyboard()
                }
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
        dismissSearchKeyboard()
        scope = .active
        path = [target]
        appState.clearPendingChat()
    }

    // MARK: - Search

    private var chatListSearchControls: some View {
        HStack(alignment: .bottom, spacing: BottomInputChromeLayout.rowSpacing) {
            bottomInputGlassContainer {
                chatSearchBar
            }
            bottomInputGlassContainer {
                searchActionButton
            }
        }
        .keyboardAdaptiveHorizontalPadding(isKeyboardVisible: $isKeyboardVisible)
        .padding(.top, BottomInputChromeLayout.topInset)
        .padding(.bottom, BottomInputChromeLayout.bottomInset)
        .keyboardAdaptiveBottomPadding()
    }

    private var chatSearchBar: some View {
        HStack(alignment: .bottom, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: BottomInputChromeLayout.inlineAccessoryIconSize, weight: .medium))
                    .foregroundStyle(.secondary)

                ZStack(alignment: .leading) {
                    if searchText.isEmpty {
                        Text("Search")
                            .font(.system(size: BottomInputChromeLayout.fieldFontSize))
                            .foregroundStyle(searchPlaceholderColor)
                            .allowsHitTesting(false)
                    }

                    TextField("", text: $searchText, onEditingChanged: { isEditing in
                        searchEditing = isEditing
                    })
                    .focused($searchFocused)
                    .font(.system(size: BottomInputChromeLayout.fieldFontSize))
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: searchFocused) { _, isFocused in
                        searchEditing = isFocused
                    }
                }
            }
            .padding(.leading, BottomInputChromeLayout.fieldLeadingPadding)
            .padding(.vertical, BottomInputChromeLayout.fieldVerticalPadding)
            .padding(.trailing, BottomInputChromeLayout.fieldTrailingPadding)
        }
        .frame(minHeight: BottomInputChromeLayout.controlSize)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { focusSearchField() })
        .compatibleInputCapsuleChrome(interactive: false)
    }

    private var searchActionButton: some View {
        Button(action: searchActionTapped) {
            Group {
                if searchCancellationActive {
                    Image(systemName: "xmark")
                } else {
                    Image(systemName: "square.and.pencil")
                        .offset(x: 0.85, y: -1.25)
                }
            }
            .font(.system(size: BottomInputChromeLayout.sideControlIconSize, weight: .semibold))
            .foregroundStyle(searchCancellationActive ? Color.secondary : Color.primary)
            .frame(width: BottomInputChromeLayout.controlSize, height: BottomInputChromeLayout.controlSize)
            .compatibleInputCircleChrome()
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(searchCancellationActive ? "Clear search" : "New chat")
    }

    private var searchPlaceholderColor: Color {
        colorScheme == .light ? Color.primary.opacity(0.38) : Color.secondary
    }

    private func searchActionTapped() {
        if searchCancellationActive {
            cancelSearch()
        } else {
            showNewChat = true
        }
    }

    private func focusSearchField() {
        Task { @MainActor in
            await Task.yield()
            searchFocused = true
            searchEditing = true
        }
    }

    private func dismissSearchKeyboard() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            searchEditing = false
            searchFocused = false
        }
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func cancelSearch() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            searchText = ""
            searchEditing = false
            searchFocused = false
        }
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
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

    // MARK: - Filter

    private var filterMenu: some View {
        let filterIcon = scope == .active
            ? "line.3.horizontal.decrease.circle"
            : "line.3.horizontal.decrease.circle.fill"

        return Menu {
            Picker("Filter", selection: $scope) {
                ForEach(ChatScope.allCases, id: \.self) { scope in
                    Label(scope.title, systemImage: scope.systemImage)
                        .tag(scope)
                }
            }
        } label: {
            Label("Filter", systemImage: filterIcon)
        }
        .accessibilityLabel("Filter chats")
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
                    // A plain button keeps the trailing slot available for the
                    // message timestamp (no disclosure chevron). Its tap target
                    // is only the label's opaque content, so the explicit
                    // content shape is required: without it the transparent
                    // Spacer gap between a short title/preview and the
                    // timestamp swallows taps.
                    Button {
                        navigate(to: item)
                    } label: {
                        ChatRow(item: item)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        swipeActions(for: item)
                    }
                    // Drop the separator above the very first row.
                    .listRowSeparator(
                        item.id == rows.first?.id ? .hidden : .automatic,
                        edges: .top
                    )
                    .listRowSeparatorTint(Color(.separator).opacity(0.35))
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }
            .listStyle(.plain)
            .compatibleBottomScrollEdgeEffect()
            .overlay {
                if rows.isEmpty { emptyState }
            }
            .refreshable { await viewModel.refreshRows() }
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
        } else if scope == .unread {
            ContentUnavailableView("No unread chats", systemImage: "circle")
        } else {
            EmptyChatsState(action: { showNewChat = true })
        }
    }

    private func currentRows(_ viewModel: ChatsListViewModel) -> [ChatsListViewModel.Item] {
        let base: [ChatsListViewModel.Item]
        switch scope {
        case .active:
            base = viewModel.items
        case .archived:
            base = viewModel.archivedItems
        case .unread:
            base = viewModel.items.filter(\.hasUnread)
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !query.isEmpty else { return base }
        return base.filter { $0.searchHaystack.contains(query) }
    }

    private func navigate(to item: ChatsListViewModel.Item) {
        dismissSearchKeyboard()
        path.append(
            ChatNavigationTarget(
                groupIdHex: item.id,
                messageIdHex: item.firstUnreadMessageIdHex
            )
        )
    }

    @ViewBuilder
    private func swipeActions(for item: ChatsListViewModel.Item) -> some View {
        if item.isArchived {
            Button {
                Task { await setArchived(groupIdHex: item.id, archived: false) }
            } label: {
                Label("Unarchive", systemImage: "tray.and.arrow.up")
            }
            .tint(.blue)
            Button(role: .destructive) {
                Task { await leave(groupIdHex: item.id) }
            } label: {
                Label("Leave", systemImage: "person.crop.circle.badge.minus")
            }
        } else {
            Button(role: .destructive) {
                Task { await leave(groupIdHex: item.id) }
            } label: {
                Label("Leave", systemImage: "person.crop.circle.badge.minus")
            }
            Button {
                Task { await setArchived(groupIdHex: item.id, archived: true) }
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
    private func leave(groupIdHex: String) async {
        guard let ref = appState.activeAccountRef else { return }
        do {
            _ = try await appState.marmot.leaveGroup(
                accountRef: ref,
                groupIdHex: groupIdHex
            )
            Haptics.warning()
        } catch {
            Haptics.error()
            appState.present(.error(L10n.string("Couldn't leave chat"), message: error.localizedDescription))
        }
    }

    @MainActor
    private func setArchived(groupIdHex: String, archived: Bool) async {
        guard let ref = appState.activeAccountRef else { return }
        do {
            let updated = try await appState.marmot.setGroupArchived(
                accountRef: ref,
                groupIdHex: groupIdHex,
                archived: archived
            )
            // The chats subscription only fires on transport events, not local
            // projection writes, so reflect the archive change immediately.
            viewModel?.applyLocalGroupChange(updated)
            Haptics.success()
        } catch {
            Haptics.error()
            appState.present(.error(L10n.string("Couldn't archive chat"), message: error.localizedDescription))
        }
    }
}

/// Resolves a group id to its conversation. A just-created or deep-linked
/// chat may not be in the list yet, so show a spinner until the chats
/// subscription delivers it. Once the row exists, load the authoritative group
/// record before opening the conversation so membership/admin metadata is not
/// inferred from the chat-list projection. Fall back to an unavailable state if it
/// never arrives (e.g. a link to a chat this account isn't a member of).
private struct ChatDestination: View {
    let target: ChatsListView.ChatNavigationTarget
    let viewModel: ChatsListViewModel
    let appState: AppState
    @State private var timedOut = false
    @State private var resolvedGroup: AppGroupRecordFfi?
    @State private var loadingGroupId: String?
    @State private var loadError: String?

    private var item: ChatsListViewModel.Item? {
        (viewModel.items + viewModel.archivedItems)
            .first(where: { $0.id == target.groupIdHex })
    }

    var body: some View {
        if let item {
            Group {
                if let resolvedGroup, resolvedGroup.groupIdHex == item.id {
                    ConversationView(
                        chat: resolvedGroup,
                        initialTitle: item.title,
                        initialTargetMessageIdHex: target.messageIdHex,
                        initialAppState: appState,
                        onChatListRowUpdated: { viewModel.applyChatListRow($0) },
                        onGroupChanged: { viewModel.applyLocalGroupChange($0) }
                    )
                } else if let loadError, loadingGroupId == item.id {
                    ContentUnavailableView {
                        Label("Couldn't load conversation", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Retry") {
                            Task { await resolveGroup(for: item, force: true) }
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: item.id) {
                await resolveGroup(for: item)
            }
        } else if timedOut {
            // A slow network can take longer than the spin-wait to deliver the
            // chat-list row. Offer Retry instead of a dead end so the user can
            // wait out another window rather than being told the chat is gone (#71).
            ContentUnavailableView {
                Label("Chat unavailable", systemImage: "questionmark.circle")
            } description: {
                Text("It may still be syncing. Try again in a moment.")
            } actions: {
                Button("Retry") { timedOut = false }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    timedOut = true
                }
        }
    }

    @MainActor
    private func resolveGroup(for item: ChatsListViewModel.Item, force: Bool = false) async {
        guard force || resolvedGroup?.groupIdHex != item.id || loadError != nil else { return }
        guard let accountRef = appState.activeAccountRef else {
            loadingGroupId = item.id
            loadError = L10n.string("No active account.")
            return
        }

        loadingGroupId = item.id
        loadError = nil
        do {
            let details = try await appState.marmot.groupDetails(accountRef: accountRef, groupIdHex: item.id)
            guard !Task.isCancelled else { return }
            resolvedGroup = details.group
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
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

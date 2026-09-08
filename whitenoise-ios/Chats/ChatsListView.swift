import SwiftUI
import MarmotKit

struct ChatsListView: View {
    @State private var showDiagnosticsPrompt = false
    @State private var chatsVisible = false
    @State private var secondarySheetVisible = false

    private var canPresentDiagnostics: Bool {
        appState.diagnosticsConsent.canPresent(
            chatsVisible: chatsVisible && path.isEmpty,
            anotherSheetVisible: showSettings || showNewChat || secondarySheetVisible,
            runtimeReady: appState.canUseRuntimeForLocalForegroundWork && appState.activeAccountRef != nil,
            chatNavigationPending: appState.pendingChatId != nil
        )
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppState.self) private var appState
    @State private var viewModel: ChatsListViewModel?
    @State private var showNewChat = false
    @State private var showSettings = false
    @State private var path: [ChatNavigationTarget] = []
    @State private var search = ChatListSearchPresentation()
    @State private var scope: ChatScope = .active
    @State private var selectedChatIds = Set<String>()
    @State private var chatListEditMode: EditMode = .inactive
    @State private var showBulkDeleteConfirmation = false
    @State private var pendingSingleDelete: LocalDeleteTarget?
    @State private var deletingChatIds = Set<String>()
    @State private var updatingChatIds = Set<String>()
    @State private var leaveActionState = ChatListLeaveActionState()
    @State private var bulkDeleteInProgress = false
    @State private var isUpdatingPinnedOrder = false
    @State private var isPinMutationInProgress = false
    @State private var isMarkingAllRead = false

    private struct LocalDeleteTarget: Equatable {
        let id: String
        let title: String
    }

    private struct VisibleRowsKey: Equatable {
        let scope: ChatScope
        let searchText: String
        let revision: Int
    }

    enum ChatScope: CaseIterable, Hashable {
        case active, unread, archived, left

        var title: LocalizedStringKey {
            switch self {
            case .active: "Chats"
            case .unread: "Unread"
            case .archived: "Archived"
            case .left: "Left"
            }
        }

        var systemImage: String {
            switch self {
            case .active: "bubble.left.and.bubble.right"
            case .unread: "message.badge"
            case .archived: "archivebox"
            case .left: "rectangle.portrait.and.arrow.right"
            }
        }
    }

    struct ChatNavigationTarget: Hashable {
        let groupIdHex: String
        let messageIdHex: String?
        let unreadMessageIdHex: String?

        init(
            groupIdHex: String,
            messageIdHex: String? = nil,
            unreadMessageIdHex: String? = nil
        ) {
            self.groupIdHex = groupIdHex
            let messageId = messageIdHex?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.messageIdHex = messageId?.isEmpty == false ? messageId : nil
            let unreadMessageId = unreadMessageIdHex?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.unreadMessageIdHex = unreadMessageId?.isEmpty == false ? unreadMessageId : nil
        }
    }

    var body: some View {
        let visibleRows = viewModel.map(currentRows) ?? []
        let visibleRowIds = Set(visibleRows.map(\.id))
        let visibleRowsKey = VisibleRowsKey(
            scope: scope,
            searchText: search.query,
            revision: viewModel?.visibleRowsRevision ?? 0
        )
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Group {
                    if let viewModel {
                        content(viewModel: viewModel, rows: visibleRows)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                if selectionMode, viewModel != nil {
                    chatSelectionBar(visibleRows: visibleRows)
                } else if search.isActive {
                    WNSearchBar(
                        query: $search.query,
                        prompt: "Search Chats",
                        onClose: exitSearch
                    )
                }
            }
            .modifier(
                ChatListReadAllBottomBar(
                    isVisible: !selectionMode
                        && scope == .unread
                        && viewModel?.items.contains(where: \.hasUnread) == true,
                    isLoading: isMarkingAllRead,
                    action: { Task { await markAllChatsRead() } }
                )
            )
            .task(id: visibleRowsKey) {
                selectedChatIds = ChatListSelection.reconcile(selectedChatIds, visibleIds: visibleRowIds)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarLeading) {
                        settingsButton
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        settingsButton
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    filterMenu
                        .tint(.primary)
                    if !search.isActive {
                        searchButton
                            .tint(.primary)
                    }
                    newChatButton
                        .tint(.primary)
                }
            }
            .compatibleTopSafeAreaBar(spacing: 0) {
                VStack(spacing: 0) {
                    if appState.isConnectivityCatchUpInProgress {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Syncing…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.bar)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Color.clear
                        .frame(height: 6)
                }
            }
            .animation(.smooth(duration: 0.2), value: appState.isConnectivityCatchUpInProgress)
            // Registered at a stable level so navigation works even when the
            // visible list is empty (e.g. just-created or deep-linked chats).
            .navigationDestination(for: ChatNavigationTarget.self) { target in
                if let viewModel {
                    ChatDestination(
                        target: target,
                        viewModel: viewModel,
                        appState: appState,
                        onGroupLeft: { groupIdHex in
                            viewModel.markGroupLeft(groupIdHex: groupIdHex)
                            path.removeAll { $0.groupIdHex == groupIdHex }
                        },
                        onGroupDeleted: { groupIdHex in
                            viewModel.removeChatListRow(groupIdHex: groupIdHex)
                            path.removeAll { $0.groupIdHex == groupIdHex }
                        }
                    )
                }
            }
            .onAppear {
                chatsVisible = true
                appState.productAnalytics.record(.screen(.inbox))
                if appState.openSettingsAfterProfileSelection {
                    appState.openSettingsAfterProfileSelection = false
                    showSettings = true
                }
                if canPresentDiagnostics { showDiagnosticsPrompt = true }
            }
            .onDisappear { chatsVisible = false }
            .onChange(of: appState.openSettingsAfterProfileSelection) {
                if appState.openSettingsAfterProfileSelection {
                    appState.openSettingsAfterProfileSelection = false
                    showSettings = true
                }
            }
            .onChange(of: canPresentDiagnostics) {
                if canPresentDiagnostics { showDiagnosticsPrompt = true }
            }
            .sheet(isPresented: $showDiagnosticsPrompt) {
                NavigationStack { DiagnosticsAndImprovementsView(isPrompt: true) }
                    .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
                    .presentationDragIndicator(.visible)
                    .appAppearance()
            }
            .sheet(isPresented: $showNewChat, onDismiss: { secondarySheetVisible = false }) {
                NewChatFlowView()
                    .onAppear { secondarySheetVisible = true }
                    .appAppearance()
            }
            .sheet(isPresented: $showSettings, onDismiss: { secondarySheetVisible = false }) {
                NavigationStack {
                    SettingsView()
                        .onAppear { secondarySheetVisible = true }
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showSettings = false }
                            }
                        }
                }
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
                viewModel?.refreshDisplayProjections()
                Task { await viewModel?.refreshRows() }
            }
            .onChange(of: appState.profileRefreshGeneration) { _, _ in
                viewModel?.refreshDisplayProjections()
            }
            // A query typed against the previous profile's chats must not
            // survive into the next one's list.
            .onChange(of: appState.activeAccountRef) { _, _ in
                exitSearch()
            }
            .onChange(of: path.count) { oldCount, count in
                if count > 0 || (oldCount > 0 && count == 0) {
                    exitSearch()
                }
                if oldCount > 0 && count == 0 {
                    viewModel?.refreshDisplayProjections()
                }
            }
            .confirmationDialog(
                singleDeleteConfirmationTitle,
                isPresented: singleDeleteConfirmationPresented,
                titleVisibility: .visible
            ) {
                if let target = pendingSingleDelete {
                    Button("Delete Chat", role: .destructive) {
                        pendingSingleDelete = nil
                        Task { _ = await deleteLocal(groupIdHex: target.id) }
                    }
                }
                Button("Cancel", role: .cancel) { pendingSingleDelete = nil }
            } message: {
                Text("This permanently removes the chat and its messages from this device. Signing in again won’t restore them.")
            }
            .confirmationDialog(
                leaveConfirmationTitle,
                isPresented: leaveConfirmationPresented,
                titleVisibility: .visible
            ) {
                if let target = leaveActionState.pendingConfirmation {
                    Button("Leave Chat", role: .destructive) {
                        startConfirmedLeave(target)
                    }
                }
                Button("Cancel", role: .cancel) {
                    leaveActionState.cancelConfirmation()
                }
            } message: {
                Text(ChatListLeavePresentation.confirmationMessage)
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
    ///
    /// Two-phase on purpose: replacing the path in one shot while a deep
    /// stack (details → profile → flow sheet) is tearing down makes
    /// NavigationStack silently restore the old path. Popping to root always
    /// sticks; the clean push follows once the unwind has settled. The
    /// pending id stays set until the final phase so deeper views' unwind
    /// observers are guaranteed to see it.
    private func consumePendingChat() {
        guard let newId = appState.pendingChatId else { return }
        showNewChat = false
        showSettings = false
        exitSearch()
        scope = .active
        path = []
        Task { @MainActor in
            // Cascaded dismissals (flow sheet → profile → details) each take
            // an animation beat, and a push landing mid-cascade gets
            // reverted. No fixed delay wins that race, so push, observe
            // whether the stack kept it, and retry until it sticks.
            for attempt in 0..<8 {
                try? await Task.sleep(nanoseconds: attempt == 0 ? 350_000_000 : 450_000_000)
                guard appState.pendingChatId == newId else { return }
                // Re-read the anchor so a newer jump for the same chat wins.
                let target = ChatNavigationTarget(
                    groupIdHex: newId,
                    messageIdHex: appState.pendingChatMessageIdHex
                )
                path = [target]
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard appState.pendingChatId == newId else { return }
                if path == [target] {
                    appState.clearPendingChat()
                    return
                }
                path = []
            }
            appState.clearPendingChat()
        }
    }

    /// Every exit funnels here; removing the bar takes the keyboard with it.
    private func exitSearch() {
        search.exit()
    }

    private var subscriptionScope: SubscriptionScope {
        SubscriptionScope(
            accountRef: appState.activeAccountRef,
            runtimeGeneration: appState.runtimeGeneration,
            isAppSceneActive: appState.isAppSceneActive
        )
    }

    struct SubscriptionScope: Hashable {
        let accountRef: String?
        let runtimeGeneration: Int
        let isAppSceneActive: Bool
    }

    // MARK: - Filter

    private var searchButton: some View {
        Button {
            search.activate()
        } label: {
            Label("Search Chats", systemImage: "magnifyingglass")
                .labelStyle(.iconOnly)
                .foregroundStyle(.primary)
        }
    }

    private var newChatButton: some View {
        Button {
            showNewChat = true
        } label: {
            Label("New Message", systemImage: "plus.bubble")
                .labelStyle(.iconOnly)
                .foregroundStyle(.primary)
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Filter", selection: $scope) {
                ForEach(ChatScope.allCases, id: \.self) { scope in
                    Label(scope.title, systemImage: scope.systemImage)
                        .tag(scope)
                }
            }
        } label: {
            if scope == .active {
                Image(systemName: "line.3.horizontal.decrease")
                    .frame(width: 34, height: 34)
                    .contentShape(.rect)
            } else {
                HStack {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text(scope.title)
                }
                .font(.subheadline)
                .foregroundStyle(Color(.systemBackground))
                .padding(.trailing, 10)
                .frame(height: 34)
                .background {
                    Capsule()
                        .fill(Color.primary)
                        .padding(.leading, -5)
                }
                .contentShape(.capsule)
            }
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Filter chats")
        .accessibilityValue(Text(scope.title))
    }

    // MARK: - List

    @ViewBuilder
    private func content(
        viewModel: ChatsListViewModel,
        rows: [ChatsListViewModel.Item]
    ) -> some View {
        if viewModel.isLoading && viewModel.items.isEmpty {
            ProgressView()
        } else if let error = viewModel.loadError {
            ContentUnavailableView(
                "Couldn't load chats",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else {
            let canReorderPinnedRows = selectionMode
                && scope == .active
                && !search.isFiltering
            let pinnedRows = canReorderPinnedRows ? rows.filter(\.isPinned) : []
            let otherRows = canReorderPinnedRows ? rows.filter { !$0.isPinned } : []

            List {
                if canReorderPinnedRows {
                    ForEach(pinnedRows) { item in
                        chatListRow(item)
                    }
                    .onMove { source, destination in
                        movePinnedRows(pinnedRows, from: source, to: destination)
                    }

                    ForEach(otherRows) { item in
                        chatListRow(item)
                    }
                } else {
                    ForEach(rows) { item in
                        chatListRow(item)
                    }
                }
            }
            .environment(\.editMode, $chatListEditMode)
            .listStyle(.plain)
            .compatibleAutomaticTopScrollEdgeEffect()
            .compatibleBottomScrollEdgeEffect()
            .overlay {
                if rows.isEmpty { emptyState }
            }
            .refreshable { await viewModel.refreshRows() }
        }
    }

    private func chatListRow(_ item: ChatsListViewModel.Item) -> some View {
        let isDeleting = deletingChatIds.contains(item.id)
        let isUpdating = updatingChatIds.contains(item.id)
        let isPreparingLeave = leaveActionState.preparingGroupIds.contains(item.id)
        let isLeaving = leaveActionState.leavingGroupIds.contains(item.id)
        let rowActionInProgress = isDeleting || isUpdating || isPreparingLeave || isLeaving

        return HStack(spacing: 12) {
            if selectionMode {
                Image(systemName: selectedChatIds.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedChatIds.contains(item.id) ? Color.accentColor : .secondary)
                    .imageScale(.large)
                    .accessibilityLabel(
                        selectedChatIds.contains(item.id)
                            ? L10n.string("Deselect chat")
                            : L10n.string("Select chat")
                    )
            }
            ChatRow(item: item)
            if isDeleting {
                ProgressView()
                    .accessibilityLabel("Deleting…")
            } else if isLeaving {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("Leaving…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if isPreparingLeave {
                ProgressView()
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            guard !rowActionInProgress else { return }
            if selectionMode {
                selectedChatIds = ChatListSelection.toggling(selectedChatIds, id: item.id)
            } else {
                navigate(to: item)
            }
        }
        .onLongPressGesture {
            if !selectionMode, !rowActionInProgress {
                Haptics.selection()
                selectedChatIds = [item.id]
                chatListEditMode = .active
            }
        }
        .accessibilityAddTraits(.isButton)
        .swipeActions(edge: .leading) {
            if !selectionMode, !rowActionInProgress {
                leadingSwipeActions(for: item)
            }
        }
        .swipeActions(edge: .trailing) {
            if !selectionMode, !rowActionInProgress {
                swipeActions(for: item)
            }
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }

    @ViewBuilder
    private var emptyState: some View {
        if search.isFiltering {
            ContentUnavailableView {
                Label("No Results", systemImage: "magnifyingglass")
            } description: {
                Text("Check the spelling or try a different search.")
            }
        } else if scope == .archived {
            ContentUnavailableView(
                "No Archived Chats",
                systemImage: "archivebox",
                description: Text("Chats you archive will appear here.")
            )
        } else if scope == .unread {
            ContentUnavailableView(
                "No Unread Chats",
                systemImage: "message.badge",
                description: Text("You’re all caught up.")
            )
        } else if scope == .left {
            ContentUnavailableView(
                "No Left Chats",
                systemImage: "rectangle.portrait.and.arrow.right",
                description: Text("Chats you leave or are removed from will appear here.")
            )
        } else {
            ContentUnavailableView(
                "No Chats",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Start a new chat to send a message.")
            )
        }
    }

    private var selectionMode: Bool { chatListEditMode.isEditing }

    private func endSelectionMode() {
        selectedChatIds = []
        chatListEditMode = .inactive
    }

    private var singleDeleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingSingleDelete != nil },
            set: { presented in
                if !presented { pendingSingleDelete = nil }
            }
        )
    }

    private var singleDeleteConfirmationTitle: String {
        guard let target = pendingSingleDelete else { return L10n.string("Delete chat from this device?") }
        return L10n.formatted("Delete “%@” from this device?", target.title)
    }

    private var leaveConfirmationPresented: Binding<Bool> {
        Binding(
            get: { leaveActionState.pendingConfirmation != nil },
            set: { presented in
                if !presented {
                    leaveActionState.cancelConfirmation()
                }
            }
        )
    }

    private var leaveConfirmationTitle: String {
        guard let target = leaveActionState.pendingConfirmation else {
            return L10n.string("Leave this chat?")
        }
        return ChatListLeavePresentation.confirmationTitle(for: target)
    }

    private func chatSelectionBar(visibleRows: [ChatsListViewModel.Item]) -> some View {
        let items = visibleRows.filter { selectedChatIds.contains($0.id) }
        let archiveAction = ChatListSelection.bulkArchiveAction(archivedFlags: items.map(\.isArchived))
        let willMute = ChatListSelection.bulkMuteMutes(mutedFlags: items.map(\.isMuted))
        let canDeleteLocally = ChatListSelection.canDeleteLocally(
            activeMemberFlags: items.map(\.isActiveMember),
            pendingLeaveFlags: items.map(\.leaveRequestPending)
        )

        return VStack(spacing: 8) {
            HStack {
                Button("Done") { endSelectionMode() }
                    .disabled(bulkDeleteInProgress)
                Spacer()
                Text(L10n.plural("%lld selected", Int64(items.count)))
                    .font(.headline)
                Spacer()
                Button("Select All") { selectedChatIds = ChatListSelection.selectAll(visibleRows.map(\.id)) }
                    .disabled(bulkDeleteInProgress)
            }

            HStack(spacing: 24) {
                selectionAction(
                    archiveAction == .unarchive ? "Unarchive" : "Archive",
                    systemImage: archiveAction == .unarchive ? "tray.and.arrow.up" : "archivebox"
                ) {
                    let archived = archiveAction == .archive
                    for id in items.map(\.id) {
                        await setArchived(groupIdHex: id, archived: archived)
                    }
                    endSelectionMode()
                }
                .disabled(bulkDeleteInProgress)

                selectionAction(
                    willMute ? "Mute" : "Unmute",
                    systemImage: willMute ? "bell.slash" : "bell"
                ) {
                    for id in items.map(\.id) { setMuted(groupIdHex: id, muted: willMute) }
                    endSelectionMode()
                }
                .disabled(bulkDeleteInProgress || items.contains(where: \.leaveRequestPending))

                if bulkDeleteInProgress {
                    VStack(spacing: 3) {
                        ProgressView()
                        Text("Deleting…").font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                } else if canDeleteLocally {
                    selectionAction("Delete", systemImage: "trash", role: .destructive) {
                        showBulkDeleteConfirmation = true
                    }
                    .confirmationDialog(
                        L10n.plural("Delete %lld chats from this device?", Int64(items.count)),
                        isPresented: $showBulkDeleteConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Delete Chats", role: .destructive) {
                            startBulkDelete(items)
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This permanently removes these chats and their messages from this device. Signing in again won’t restore them.")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.regularMaterial)
    }

    private func selectionAction(
        _ title: LocalizedStringKey,
        systemImage: String,
        role: ButtonRole? = nil,
        perform: @escaping () async -> Void
    ) -> some View {
        Button(role: role) {
            Task { await perform() }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage).imageScale(.large)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(selectedChatIds.isEmpty)
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
        case .left:
            base = viewModel.items.filter { !$0.isActiveMember }
        }
        return base.filter {
            ChatListSearch.matches(query: search.query, in: $0.searchHaystack)
        }
    }

    @MainActor
    private func movePinnedRows(
        _ pinnedRows: [ChatsListViewModel.Item],
        from source: IndexSet,
        to destination: Int
    ) {
        guard !isUpdatingPinnedOrder else { return }
        var orderedGroupIds = pinnedRows.map(\.id)
        let previousOrder = orderedGroupIds
        orderedGroupIds.move(fromOffsets: source, toOffset: destination)
        guard orderedGroupIds != previousOrder else { return }

        isUpdatingPinnedOrder = true
        viewModel?.applyPinnedOrder(orderedGroupIds)
        Task { await persistPinnedOrder(orderedGroupIds) }
    }

    @MainActor
    private func persistPinnedOrder(_ orderedGroupIds: [String]) async {
        defer { isUpdatingPinnedOrder = false }
        guard let ref = appState.activeAccountRef, let viewModel else {
            presentChatMutationFailure(title: L10n.string("Couldn't update pin"))
            return
        }

        do {
            let client = try appState.currentMarmotClient()
            let state = try await client.setPinnedChatOrder(
                accountRef: ref,
                orderedGroupIds: orderedGroupIds
            )
            viewModel.applyPinnedOrder(state.orderedGroupIds)
        } catch {
            await viewModel.refreshRows()
            presentChatMutationFailure(title: L10n.string("Couldn't update pin"))
        }
    }

    private func navigate(to item: ChatsListViewModel.Item) {
        exitSearch()
        path.append(
            ChatNavigationTarget(
                groupIdHex: item.id,
                messageIdHex: item.firstUnreadMessageIdHex,
                unreadMessageIdHex: item.firstUnreadMessageIdHex
            )
        )
    }

    @ViewBuilder
    private func leadingSwipeActions(for item: ChatsListViewModel.Item) -> some View {
        let actions = ChatListSwipeActionsPresentation.leadingActions(
            hasUnread: item.hasUnread,
            isPinned: item.isPinned,
            isArchived: item.isArchived
        )

        if actions.contains(.read) {
            Button {
                Task { await markRead(item) }
            } label: {
                Label(L10n.string("Mark as read"), systemImage: "checkmark.message")
            }
            .tint(.blue)
        }
        if actions.contains(.unread) {
            Button {
                Task { await markUnread(item) }
            } label: {
                Label(L10n.string("Mark as unread"), systemImage: "envelope.badge")
            }
            .tint(.blue)
        }
        if actions.contains(.unpin) {
            Button {
                Task { await setPinned(item, pinned: false) }
            } label: {
                Label(L10n.string("Unpin"), systemImage: "pin.slash")
            }
            .tint(.orange)
        }
        if actions.contains(.pin) {
            Button {
                Task { await setPinned(item, pinned: true) }
            } label: {
                Label(L10n.string("Pin"), systemImage: "pin")
            }
            .tint(.orange)
        }
    }

    @ViewBuilder
    private func swipeActions(for item: ChatsListViewModel.Item) -> some View {
        let actions = ChatListSwipeActionsPresentation.trailingActions(
            isArchived: item.isArchived,
            selfMembership: item.selfMembership,
            leaveRequestPending: item.leaveRequestPending,
            isMuted: item.isMuted
        )

        if actions.contains(.unmute) {
            Button {
                setMuted(groupIdHex: item.id, muted: false)
            } label: {
                Label(L10n.string("Unmute"), systemImage: "bell.fill")
            }
            .tint(.indigo)
        }
        if actions.contains(.mute) {
            Button {
                setMuted(groupIdHex: item.id, muted: true)
            } label: {
                Label(L10n.string("Mute"), systemImage: "bell.slash.fill")
            }
            .tint(.indigo)
        }
        if actions.contains(.unarchive) {
            Button {
                Task { await setArchived(groupIdHex: item.id, archived: false) }
            } label: {
                Label("Unarchive", systemImage: "tray.and.arrow.up")
            }
            .tint(.blue)
        }
        if actions.contains(.delete) {
            // A destructive-role swipe button makes SwiftUI optimistically
            // remove the row before our confirmation dialog has resolved.
            Button {
                pendingSingleDelete = LocalDeleteTarget(id: item.id, title: item.title)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
        if actions.contains(.leave) {
            Button {
                let target = ChatListLeavePresentation.Target(
                    groupIdHex: item.id,
                    title: item.title
                )
                Task { await prepareLeave(target) }
            } label: {
                Label("Leave", systemImage: "person.crop.circle.badge.minus")
            }
            .tint(.red)
        }
        if actions.contains(.archive) {
            Button {
                Task { await setArchived(groupIdHex: item.id, archived: true) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.gray)
        }
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            if let active = appState.activeAccount {
                AvatarBubble(
                    seed: active.accountIdHex,
                    title: appState.displayName(forAccountIdHex: active.accountIdHex),
                    pictureURL: appState.avatarURL(forAccountIdHex: active.accountIdHex)
                )
                .frame(width: 44, height: 44)
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }

    @MainActor
    private func markRead(_ item: ChatsListViewModel.Item) async {
        guard updatingChatIds.insert(item.id).inserted else { return }
        defer { updatingChatIds.remove(item.id) }
        let succeeded: Bool
        if let messageIdHex = item.lastMessage?.messageIdHex {
            succeeded = await markRead(
                groupIdHex: item.id,
                messageIdHex: messageIdHex
            )
        } else if item.row.manuallyMarkedUnread {
            succeeded = await setManuallyUnread(item, manuallyUnread: false)
        } else {
            succeeded = false
        }
        if !succeeded {
            presentMarkReadFailure()
        }
    }

    @MainActor
    private func markUnread(_ item: ChatsListViewModel.Item) async {
        guard updatingChatIds.insert(item.id).inserted else { return }
        defer { updatingChatIds.remove(item.id) }
        guard await setManuallyUnread(item, manuallyUnread: true) else {
            presentChatMutationFailure(title: L10n.string("Couldn't mark as unread"))
            return
        }
    }

    @MainActor
    private func setManuallyUnread(
        _ item: ChatsListViewModel.Item,
        manuallyUnread: Bool
    ) async -> Bool {
        guard let ref = appState.activeAccountRef else { return false }
        do {
            let client = try appState.currentMarmotClient()
            if let row = try await client.setChatManuallyUnread(
                accountRef: ref,
                groupIdHex: item.id,
                manuallyUnread: manuallyUnread
            ) {
                viewModel?.applyChatListRow(row)
            } else {
                await viewModel?.refreshRows()
            }
            return true
        } catch {
            return false
        }
    }

    @MainActor
    private func setPinned(_ item: ChatsListViewModel.Item, pinned: Bool) async {
        guard !isPinMutationInProgress, updatingChatIds.insert(item.id).inserted else { return }
        isPinMutationInProgress = true
        defer {
            isPinMutationInProgress = false
            updatingChatIds.remove(item.id)
        }
        guard let ref = appState.activeAccountRef, let viewModel else {
            presentChatMutationFailure(title: L10n.string("Couldn't update pin"))
            return
        }
        let transitionID = viewModel.beginPinOrderUITransition()
        // SwiftUI exposes no completion callback for the system swipe drawer.
        let swipeDrawerCloseTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
        }
        do {
            let client = try appState.currentMarmotClient()
            let state = try await client.setChatPinned(
                accountRef: ref,
                groupIdHex: item.id,
                pinned: pinned
            )
            await swipeDrawerCloseTask.value
            await Task.yield()
            withAnimation(.smooth(duration: 0.25)) {
                _ = viewModel.finishPinOrderUITransition(
                    transitionID: transitionID,
                    orderedGroupIds: state.orderedGroupIds
                )
            }
        } catch {
            await swipeDrawerCloseTask.value
            var appliedDeferredSnapshot = false
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                appliedDeferredSnapshot = viewModel.finishPinOrderUITransition(
                    transitionID: transitionID,
                    orderedGroupIds: nil
                )
            }
            if !appliedDeferredSnapshot {
                await viewModel.refreshRows()
            }
            presentChatMutationFailure(title: L10n.string("Couldn't update pin"))
        }
    }

    @MainActor
    private func markAllChatsRead() async {
        guard !isMarkingAllRead, let viewModel else { return }
        isMarkingAllRead = true
        defer { isMarkingAllRead = false }

        var hadFailure = false
        for item in viewModel.items where item.hasUnread {
            if let messageIdHex = item.lastMessage?.messageIdHex {
                if !(await markRead(groupIdHex: item.id, messageIdHex: messageIdHex)) {
                    hadFailure = true
                }
            } else if item.row.manuallyMarkedUnread {
                if !(await setManuallyUnread(item, manuallyUnread: false)) {
                    hadFailure = true
                }
            } else {
                hadFailure = true
            }
        }
        if hadFailure {
            presentMarkReadFailure()
        }
    }

    @MainActor
    private func markRead(groupIdHex: String, messageIdHex: String) async -> Bool {
        guard let ref = appState.activeAccountRef else { return false }
        do {
            let client = try appState.currentMarmotClient()
            guard let result = await client.markTimelineMessagesRead(
                accountRef: ref,
                groupIdHex: groupIdHex,
                messageIdHexes: [messageIdHex]
            ).first, result.succeeded else {
                return false
            }
            if let row = result.row {
                viewModel?.applyChatListRow(row)
            } else {
                await viewModel?.refreshRows()
            }
            await appState.notifications.reconcileDeliveredNotificationsAfterRead(
                accountRef: ref,
                groupIdHex: groupIdHex,
                readMessageIdHexes: [messageIdHex],
                conversationStillHasUnread: result.row?.hasUnread
            )
            return true
        } catch {
            return false
        }
    }

    private func presentMarkReadFailure() {
        presentChatMutationFailure(title: L10n.string("Couldn't mark as read"))
    }

    private func presentChatMutationFailure(title: String) {
        Haptics.error()
        appState.present(.error(
            title,
            message: L10n.string("Try again.")
        ))
    }

    @MainActor
    private func startBulkDelete(_ items: [ChatsListViewModel.Item]) {
        guard !bulkDeleteInProgress else { return }
        let targets = items.map { LocalDeleteTarget(id: $0.id, title: $0.title) }
        bulkDeleteInProgress = true
        Task { @MainActor in
            defer { bulkDeleteInProgress = false }
            var failedIds = Set<String>()
            for target in targets {
                let deleted = await deleteLocal(groupIdHex: target.id, presentsFailure: false)
                if !deleted { failedIds.insert(target.id) }
            }
            guard !failedIds.isEmpty else {
                endSelectionMode()
                return
            }
            selectedChatIds = failedIds
            Haptics.error()
            appState.present(.error(
                L10n.string("Some chats couldn’t be deleted"),
                message: L10n.plural("%lld chats remain. Try again.", Int64(failedIds.count))
            ))
        }
    }

    @MainActor
    @discardableResult
    private func deleteLocal(groupIdHex: String, presentsFailure: Bool = true) async -> Bool {
        guard !deletingChatIds.contains(groupIdHex) else { return false }
        guard let ref = appState.activeAccountRef else { return false }
        deletingChatIds.insert(groupIdHex)
        defer { deletingChatIds.remove(groupIdHex) }
        do {
            let client = try appState.currentMarmotClient()
            _ = try await client.deleteGroupLocal(
                accountRef: ref,
                groupIdHex: groupIdHex
            )
            viewModel?.removeChatListRow(groupIdHex: groupIdHex)
            Haptics.warning()
            return true
        } catch {
            if presentsFailure {
                Haptics.error()
                appState.present(.error(
                    L10n.string("Couldn't delete chat"),
                    message: L10n.string("Try again.")
                ))
            }
            return false
        }
    }

    @MainActor
    private func prepareLeave(_ target: ChatListLeavePresentation.Target) async {
        guard let ref = appState.activeAccountRef,
              leaveActionState.beginPreparation(for: target)
        else { return }
        do {
            let managementState = try await appState.currentMarmotClient().groupManagementState(
                accountRef: ref,
                groupIdHex: target.groupIdHex
            )
            guard viewModel?.item(groupIdHex: target.groupIdHex)?.isActiveMember == true else {
                leaveActionState.finishPreparation(for: target, canPresentConfirmation: false)
                return
            }
            if managementState.leaveRequestPending {
                viewModel?.markGroupLeft(groupIdHex: target.groupIdHex)
                leaveActionState.finishPreparation(for: target, canPresentConfirmation: false)
                return
            }
            guard GroupManagementPresentation.canLeave(
                state: managementState,
                fallbackIsLastAdmin: false
            ) else {
                leaveActionState.finishPreparation(for: target, canPresentConfirmation: false)
                presentCannotLeave(managementState)
                return
            }
            leaveActionState.finishPreparation(for: target, canPresentConfirmation: true)
        } catch {
            leaveActionState.finishPreparation(for: target, canPresentConfirmation: false)
            presentLeaveFailure()
        }
    }

    @MainActor
    private func startConfirmedLeave(_ target: ChatListLeavePresentation.Target) {
        guard leaveActionState.beginConfirmedLeave(for: target) else { return }
        Task { @MainActor in
            await leaveConfirmed(groupIdHex: target.groupIdHex)
            leaveActionState.finishLeave(groupIdHex: target.groupIdHex)
        }
    }

    @MainActor
    private func leaveConfirmed(groupIdHex: String) async {
        guard let ref = appState.activeAccountRef else {
            presentLeaveFailure()
            return
        }
        do {
            let client = try appState.currentMarmotClient()
            let managementState = try await client.groupManagementState(
                accountRef: ref,
                groupIdHex: groupIdHex
            )
            if managementState.leaveRequestPending {
                viewModel?.markGroupLeft(groupIdHex: groupIdHex)
                return
            }
            guard GroupManagementPresentation.canLeave(
                state: managementState,
                fallbackIsLastAdmin: false
            ) else {
                presentCannotLeave(managementState)
                return
            }
            if GroupManagementPresentation.shouldSelfDemoteBeforeLeave(state: managementState) {
                _ = try await client.selfDemoteAdminDetailed(
                    accountRef: ref,
                    groupIdHex: groupIdHex
                )
            }
            _ = try await client.leaveGroup(
                accountRef: ref,
                groupIdHex: groupIdHex
            )
            // The chats subscription only fires on transport events, not local
            // projection writes, so reflect the inactive local-history state.
            viewModel?.markGroupLeft(groupIdHex: groupIdHex)
            Haptics.warning()
        } catch {
            let leaveIsPending = isLeaveAlreadyRequested(error)
                ? true
                : await refreshPendingLeave(groupIdHex: groupIdHex, accountRef: ref)
            if leaveIsPending {
                viewModel?.markGroupLeft(groupIdHex: groupIdHex)
                Haptics.warning()
                return
            }
            presentLeaveFailure()
        }
    }

    @MainActor
    private func refreshPendingLeave(groupIdHex: String, accountRef: String) async -> Bool {
        do {
            let state = try await appState.currentMarmotClient().groupManagementState(
                accountRef: accountRef,
                groupIdHex: groupIdHex
            )
            return state.leaveRequestPending
        } catch {
            return false
        }
    }

    private func isLeaveAlreadyRequested(_ error: Error) -> Bool {
        guard let error = error as? MarmotKitError else { return false }
        if case .LeaveAlreadyRequested = error { return true }
        return false
    }

    private func presentCannotLeave(_ managementState: GroupManagementStateFfi) {
        Haptics.error()
        appState.present(.error(
            ChatListLeavePresentation.failureTitle,
            message: GroupManagementPresentation.leaveFooter(
                state: managementState,
                fallbackIsLastAdmin: false
            ) ?? GroupManagementPresentation.leaveHelpMessage(
                state: managementState,
                fallbackIsLastAdmin: false
            )
        ))
    }

    private func presentLeaveFailure() {
        Haptics.error()
        appState.present(.error(
            ChatListLeavePresentation.failureTitle,
            message: ChatListLeavePresentation.failureMessage
        ))
    }

    /// Mute is a local, per-device preference: no Marmot publish, so the row
    /// projection is refreshed directly instead of via a group record change.
    @MainActor
    private func setMuted(groupIdHex: String, muted: Bool) {
        guard let accountIdHex = appState.activeAccount?.accountIdHex else { return }
        // Write the tri-state mode, not just the legacy set — an explicit mode
        // outranks the legacy mute on reads, so a bare setMuted would be
        // ignored for any chat the details picker ever touched.
        ChatMuteStore.setNotifyMode(muted ? .nothing : .all, accountIdHex: accountIdHex, groupIdHex: groupIdHex)
        viewModel?.refreshDisplayProjections()
        Haptics.success()
    }

    @MainActor
    private func setArchived(groupIdHex: String, archived: Bool) async {
        guard let ref = appState.activeAccountRef else { return }
        do {
            let client = try appState.currentMarmotClient()
            let updated = try await client.setGroupArchived(
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
            appState.present(UserFacingError.toast(title: L10n.string("Couldn't archive chat"), error: error))
        }
    }
}

/// Resolves a group id to its conversation. A just-created or deep-linked
/// chat may not be in the list yet, so show a spinner until the chats
/// subscription delivers it. Once the row exists, open from the projected row
/// immediately; `ConversationViewModel` refreshes authoritative group details
/// after the local timeline snapshot can render.
private struct ChatDestination: View {
    let target: ChatsListView.ChatNavigationTarget
    let viewModel: ChatsListViewModel
    let appState: AppState
    let onGroupLeft: (String) -> Void
    let onGroupDeleted: (String) -> Void
    @State private var timedOut = false

    private var item: ChatsListViewModel.Item? {
        viewModel.item(groupIdHex: target.groupIdHex)
    }

    var body: some View {
        if let item {
            ConversationView(
                chat: item.projectedGroup,
                accountRef: appState.activeAccountRef,
                initialTitle: item.title,
                initialOtherMember: item.directPeerAccountIdHex,
                initialMemberCount: item.isDirectMessage == true ? 2 : nil,
                initialLeaveRequestPending: item.leaveRequestPending,
                initialTargetMessageIdHex: target.messageIdHex,
                initialUnreadMessageIdHex: target.unreadMessageIdHex,
                initialAppState: appState,
                forwardDestinationProvider: {
                    viewModel.forwardDestinations(excludingGroupIdHex: target.groupIdHex)
                },
                onChatListRowUpdated: { viewModel.enqueueChatListRowUpdate($0) },
                onGroupChanged: { viewModel.applyLocalGroupChange($0) },
                onGroupLeft: onGroupLeft,
                onGroupDeleted: onGroupDeleted,
                onDraftChanged: { viewModel.refreshDisplayProjections() }
            )
            .id(target.groupIdHex)
            .onAppear {
                HostActionPerformance.conversationBecameVisible(groupIdHex: target.groupIdHex)
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
                    await viewModel.refreshRow(groupIdHex: target.groupIdHex)
                    guard viewModel.item(groupIdHex: target.groupIdHex) == nil else { return }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    timedOut = true
                }
        }
    }
}

private struct ChatListReadAllBottomBar: ViewModifier {
    let isVisible: Bool
    let isLoading: Bool
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isVisible {
            if #available(iOS 26.0, *) {
                content
                    .toolbar {
                        ToolbarItem(placement: .bottomBar) {
                            readAllButton
                        }
                        ToolbarSpacer(.flexible, placement: .bottomBar)
                    }
            } else {
                content
                    .toolbar {
                        ToolbarItemGroup(placement: .bottomBar) {
                            readAllButton
                            Spacer()
                        }
                    }
            }
        } else {
            content
        }
    }

    private var readAllButton: some View {
        Button(action: action) {
            if isLoading {
                ProgressView()
                    .accessibilityLabel("Marking chats as read…")
            } else {
                Text("Read All")
            }
        }
        .disabled(isLoading)
    }
}

nonisolated enum ChatListSearch {
    static func matches(
        query: String,
        in haystack: String,
        locale: Locale = .current
    ) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return haystack.range(
            of: trimmed,
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: locale
        ) != nil
    }
}

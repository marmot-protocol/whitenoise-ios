import SwiftUI
import UIKit
import MarmotKit

struct ChatsListView: View {
    private struct ConsentRuntimeState: Equatable {
        let generation: Int
        let isReady: Bool
    }

    @State private var showDiagnosticsPrompt = false
    @State private var chatsVisible = false
    @State private var secondarySheetVisible = false

    private var canPresentDiagnostics: Bool {
        appState.diagnosticsConsent.canPresent(
            chatsVisible: chatsVisible && path.isEmpty,
            anotherSheetVisible: showSettings || showNewChat || secondarySheetVisible || showBulkLeaveConfirmation
                || appState.erasureState.shouldPresentRecovery(
                    activeAccountRef: appState.activeAccountRef,
                    runtimeReady: appState.canUseRuntimeForLocalForegroundWork
                )
                || appState.pendingWipeReport != nil,
            runtimeReady: appState.canUseRuntimeForLocalForegroundWork && appState.activeAccountRef != nil,
            chatNavigationPending: appState.pendingChatId != nil
        )
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title3) private var selectionIndicatorWidth = 24.0
    @ScaledMetric(relativeTo: .body) private var selectionActionDiameter = 44.0
    @Environment(AppState.self) private var appState
    @State private var viewModel: ChatsListViewModel?
    @State private var showNewChat = false
    @State private var showSettings = false
    @State private var path: [ChatNavigationTarget] = []
    @State private var search = ChatListSearchPresentation()
    @State private var scope: ChatScope = .active
    @State private var listViewport = ChatListViewport()
    @State private var selectedChatIds = Set<String>()
    @State private var chatListEditMode: EditMode = .inactive
    @State private var showBulkDeleteConfirmation = false
    @State private var pendingSingleDelete: LocalDeleteTarget?
    @State private var deletingChatIds = Set<String>()
    @State private var updatingChatIds = Set<String>()
    @State private var leaveActionState = ChatListLeaveActionState()
    @State private var leaveConfirmationContext: ChatLeaveOperation.Context?
    @State private var bulkDeleteInProgress = false
    @State private var bulkLeave = ChatListBulkLeaveState()
    @State private var showBulkLeaveConfirmation = false
    @State private var bulkLeaveRequest: BulkLeaveRequest?
    @State private var pendingMute: MuteTarget?
    @State private var isUpdatingMutes = false
    @State private var isUpdatingPinnedOrder = false
    @State private var isPinMutationInProgress = false
    @State private var blockedUsers = BlockedUsersModel()
    @State private var isMarkingAllRead = false

    private struct BulkLeaveRequest {
        let context: ChatLeaveOperation.Context
        let targets: [ChatListLeavePresentation.Target]
    }

    private struct LocalDeleteTarget: Equatable {
        let id: String
        let title: String
    }

    private struct MuteTarget {
        let id = UUID()
        let accountRef: String
        let runtimeGeneration: Int
        let groupIds: [String]
        let fromSelection: Bool
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
        let openedAt = ContinuousClock.now
        let performanceTicket: ProductAnalyticsRecorder.Ticket?

        init(
            groupIdHex: String,
            messageIdHex: String? = nil,
            unreadMessageIdHex: String? = nil,
            performanceTicket: ProductAnalyticsRecorder.Ticket? = nil
        ) {
            self.performanceTicket = performanceTicket
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
            .sensoryFeedback(.selection, trigger: selectionMode) { _, isSelecting in isSelecting }
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
                if selectionMode {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(ChatListSelection.allSelected(selectedChatIds, visibleIds: visibleRowIds)
                               ? L10n.string("Deselect All") : L10n.string("Select All")) {
                            withAnimation(selectionAnimation) {
                                selectedChatIds = ChatListSelection.togglingAll(selectedChatIds, visibleIds: visibleRowIds)
                            }
                        }
                        .tint(.primary)
                        .disabled(selectionMutationInProgress || visibleRows.isEmpty)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close", systemImage: "xmark") { endSelectionMode() }
                            .labelStyle(.iconOnly)
                            .tint(.primary)
                            .disabled(selectionMutationInProgress)
                    }
                } else {
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
            // Chats owns the consent read: bootstrap's own refresh runs while the
            // phase is still `.bootstrapping`, so it cannot see the runtime.
            .task(id: ConsentRuntimeState(
                generation: appState.runtimeGeneration,
                isReady: appState.canUseRuntimeForLocalForegroundWork
            )) {
                guard appState.canUseRuntimeForLocalForegroundWork else { return }
                await appState.diagnosticsConsent.reload(using: appState)
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
                        .wnBackButton()
                }
                .appAppearance()
            }
            .task(id: subscriptionScope) {
                // The inbox needs the block list so a direct chat with a
                // blocked peer can say so instead of previewing their message.
                await blockedUsers.run(using: appState, target: nil)
            }
            .task(id: BlockedAuthorsToken(
                accountIdHexes: blockedUsers.blockedAccountIds,
                isViewModelReady: viewModel != nil
            )) {
                viewModel?.applyBlockedAccounts(blockedUsers.blockedAccountIds)
            }
            .task(id: subscriptionScope) {
                // Own both creation and binding here so bind() can't be skipped
                // by a nil viewModel: the lazy-creation task could fire after
                // this one, leaving the list permanently empty and unbound.
                let vm = viewModel ?? ChatsListViewModel(appState: appState)
                if viewModel == nil { viewModel = vm }
                listViewport.reset()
                let viewport = listViewport
                vm.windowWillChange = { [weak viewport] snapshot in viewport?.prepare(for: snapshot) }
                await vm.bind(accountRef: appState.activeAccountRef, force: true, mode: listMode)
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
                pendingMute = nil
                endSelectionMode()
            }
            .onChange(of: appState.runtimeGeneration) { _, _ in
                pendingMute = nil
                bulkLeave.cancelConfirmation()
                showBulkLeaveConfirmation = false
                bulkLeaveRequest = nil
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
                    messageIdHex: appState.pendingChatMessageIdHex,
                    performanceTicket: appState.productAnalytics.ticket()
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
            isAppSceneActive: appState.isAppSceneActive,
            mode: listMode
        )
    }

    struct SubscriptionScope: Hashable {
        let accountRef: String?
        let runtimeGeneration: Int
        let isAppSceneActive: Bool
        var mode: ChatsListViewModel.ListMode = .complete
    }

    private var listMode: ChatsListViewModel.ListMode {
        if search.isActive || selectionMode { return .complete }
        switch scope {
        case .active: return .window(.chats)
        case .unread: return .window(.unread)
        case .archived: return .window(.archived)
        case .left: return .window(.left)
        }
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
        if viewModel.isLoading && rows.isEmpty {
            ProgressView()
        } else if let error = viewModel.loadError {
            ContentUnavailableView(
                "Couldn't load chats",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else {
            // Keep row identity stable when selection controls appear.
            let groupsPinnedRows = scope == .active && !search.isFiltering
            let canReorderPinnedRows = selectionMode && groupsPinnedRows
            let pinnedRows = groupsPinnedRows ? rows.filter(\.isPinned) : []
            let otherRows = groupsPinnedRows ? rows.filter { !$0.isPinned } : []

            List {
                if viewModel.windowSnapshot?.hasMoreBefore == true {
                    windowPageButton(.backward, viewModel: viewModel)
                    Button("Return to newest chats") {
                        listViewport.requestTop()
                        Task { await viewModel.returnWindowToTop() }
                    }
                }
                if groupsPinnedRows {
                    ForEach(pinnedRows) { item in
                        chatListRow(item)
                            .moveDisabled(!canReorderPinnedRows)
                    }
                    .onMove { source, destination in
                        guard canReorderPinnedRows else { return }
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
                if viewModel.windowSnapshot?.hasMoreAfter == true {
                    windowPageButton(.forward, viewModel: viewModel)
                }
                if let error = viewModel.pageError {
                    Text(error).foregroundStyle(.secondary)
                }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .idle, let id = listViewport.visibleAnchor() {
                    viewModel.setVisibleWindowAnchor(id)
                }
            }
            .environment(\.editMode, $chatListEditMode)
            .listStyle(.plain)
            .compatibleAutomaticTopScrollEdgeEffect()
            .compatibleBottomScrollEdgeEffect()
            .overlay {
                if rows.isEmpty { emptyState }
            }
            .refreshable {
                if case .window = viewModel.listMode {
                    listViewport.requestTop()
                    await viewModel.returnWindowToTop()
                } else {
                    await viewModel.refreshRows()
                }
            }
        }
    }

    private func windowPageButton(
        _ direction: ChatListPageDirectionFfi, viewModel: ChatsListViewModel
    ) -> some View {
        Button {
            requestWindowPage(direction, viewModel: viewModel)
        } label: {
            HStack {
                Text(direction == .forward ? L10n.string("Load more chats") : L10n.string("Load previous chats"))
                if viewModel.isPaging { ProgressView() }
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(viewModel.isPaging)
        .modifier(TimelinePaginationVisibility(isEnabled: !viewModel.isPaging) {
            requestWindowPage(direction, viewModel: viewModel)
        })
    }

    private func requestWindowPage(_ direction: ChatListPageDirectionFfi, viewModel: ChatsListViewModel) {
        if let id = listViewport.visibleAnchor() { viewModel.setVisibleWindowAnchor(id) }
        Task { await viewModel.pageWindow(direction) }
    }

    private func chatListRow(_ item: ChatsListViewModel.Item) -> some View {
        let isDeleting = deletingChatIds.contains(item.id)
        let isUpdating = updatingChatIds.contains(item.id)
        let isPreparingLeave = leaveActionState.preparingGroupIds.contains(item.id)
        let isLeaving = leaveActionState.leavingGroupIds.contains(item.id)
        let rowActionInProgress = isDeleting || isUpdating || isPreparingLeave || isLeaving || isUpdatingMutes || bulkLeave.isBusy

        return HStack(spacing: 12) {
            if selectionMode {
                Image(systemName: selectedChatIds.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedChatIds.contains(item.id) ? Color.accentColor : .secondary)
                    .font(.title3)
                    .frame(width: selectionIndicatorWidth)
                    .accessibilityHidden(true)
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
            } else if isUpdating {
                ProgressView()
            }
        }
        .background {
            if let sequence = viewModel?.windowSnapshot?.sequence {
                ChatListRowAnchor(groupId: item.id, sequence: sequence, viewport: listViewport)
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            guard !rowActionInProgress else { return }
            if selectionMode {
                withAnimation(selectionAnimation) {
                    selectedChatIds = ChatListSelection.toggling(selectedChatIds, id: item.id)
                }
                Haptics.selection()
            } else {
                navigate(to: item)
            }
        }
        .modifier(ChatListSelectionPress(isEnabled: !selectionMode && !rowActionInProgress) {
            beginSelectionMode(id: item.id)
        })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selectionMode && selectedChatIds.contains(item.id) ? .isSelected : [])
        .accessibilityActions {
            if !selectionMode, !rowActionInProgress {
                Button("Select chat") {
                    beginSelectionMode(id: item.id)
                }
            }
        }
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
        .background(alignment: .trailing) {
            if let target = pendingMute, !target.fromSelection, target.groupIds == [item.id] {
                mutePicker(target: target, item: item)
                    .id(target.id)
                    .frame(width: 1)
                    .allowsHitTesting(false)
            }
        }
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

    private var selectionMutationInProgress: Bool {
        bulkDeleteInProgress || isUpdatingMutes || bulkLeave.isBusy
    }

    private var selectionAnimation: Animation? {
        reduceMotion ? nil : .default
    }

    private func beginSelectionMode(id: String) {
        withAnimation(selectionAnimation) {
            selectedChatIds = [id]
            chatListEditMode = .active
        }
    }

    private func endSelectionMode() {
        showBulkLeaveConfirmation = false
        bulkLeaveRequest = nil
        bulkLeave.clearSelection()
        withAnimation(selectionAnimation) {
            selectedChatIds = []
            chatListEditMode = .inactive
        }
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
        let departureActions = items.map(\.departureAction)
        let canDeleteLocally = ChatListSelection.canDeleteLocally(departureActions)

        return ChatListSelectionBar(count: items.count) {
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
            .disabled(selectionMutationInProgress)
        } trailing: {
            HStack(spacing: 12) {
                selectionMoreMenu(items)

                if bulkDeleteInProgress {
                    ProgressView()
                        .frame(width: selectionActionDiameter, height: selectionActionDiameter)
                        .wnLiftedChrome(in: .circle)
                        .accessibilityLabel("Deleting…")
                } else if canDeleteLocally {
                    selectionAction("Delete", systemImage: "trash", role: .destructive) {
                        showBulkDeleteConfirmation = true
                    }
                    .disabled(isUpdatingMutes || bulkLeave.isBusy)
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
        .sheet(isPresented: $showBulkLeaveConfirmation, onDismiss: {
            bulkLeaveRequest = nil
            bulkLeave.cancelConfirmation()
        }) {
            if let request = bulkLeaveRequest {
                ChatListLeaveConfirmationSheet(count: request.targets.count) {
                    await confirmBulkLeave(request)
                }
            }
        }
    }

    @ViewBuilder
    private func selectionMoreMenu(_ items: [ChatsListViewModel.Item]) -> some View {
        let canMute = !items.isEmpty && !items.contains { $0.departureAction == nil }
        let targets = items.filter { $0.departureAction == .leave }.map {
            ChatListLeavePresentation.Target(groupIdHex: $0.id, title: $0.title)
        }
        ChatSelectionButton(title: L10n.string("More"), systemImage: "ellipsis", menu: {
            var actions: [UIMenuElement] = []
            if canMute,
               let target = muteTarget(groupIds: items.map(\.id), fromSelection: true) {
                if ChatListSelection.bulkMuteMutes(mutedFlags: items.map(\.isMuted)) {
                    actions.append(UIMenu(title: L10n.string("Mute"), image: UIImage(systemName: "bell.slash"), children:
                        ChatMuteDuration.allCases.map { duration in
                            UIAction(title: duration.title) { _ in
                                Task { await updateMute(.mute(duration), target: target) }
                            }
                        }
                    ))
                } else {
                    actions.append(UIAction(title: L10n.string("Unmute"), image: UIImage(systemName: "bell")) { _ in
                        Task { await updateMute(.unmute, target: target) }
                    })
                }
            }
            if !targets.isEmpty, let accountRef = appState.activeAccountRef {
                let context = ChatLeaveOperation.Context(accountRef: accountRef, runtimeGeneration: appState.runtimeGeneration)
                actions.append(UIAction(
                    title: targets.count == 1 ? L10n.string("Leave Chat") : L10n.string("Leave Chats"),
                    image: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
                    attributes: .destructive
                ) { _ in
                    guard selectionMode, leaveContextIsCurrent(context) else { return }
                    bulkLeaveRequest = BulkLeaveRequest(context: context, targets: targets)
                    showBulkLeaveConfirmation = true
                })
            }
            return actions
        })
        .id([appState.activeAccountRef ?? "", String(appState.runtimeGeneration)] + items.map(\.id).sorted())
        .disabled((!canMute && targets.isEmpty) || selectionMutationInProgress
                  || !appState.canUseRuntimeForLocalForegroundWork)
    }

    private func selectionAction(
        _ title: String.LocalizationValue,
        systemImage: String,
        role: ButtonRole? = nil,
        perform: @escaping () async -> Void
    ) -> some View {
        ChatSelectionButton(
            title: L10n.string(title),
            systemImage: systemImage,
            isDestructive: role == .destructive,
            action: { Task { await perform() } }
        )
        .disabled(selectedChatIds.isEmpty)
    }

    private func currentRows(_ viewModel: ChatsListViewModel) -> [ChatsListViewModel.Item] {
        if case .window = viewModel.listMode {
            return viewModel.windowSnapshot?.rows.compactMap { viewModel.item(groupIdHex: $0.row.groupIdHex) } ?? []
        }
        let base: [ChatsListViewModel.Item]
        switch scope {
        case .active:
            base = viewModel.items.filter { !$0.belongsToLeft }
        case .archived:
            base = viewModel.archivedItems.filter { !$0.belongsToLeft }
        case .unread:
            base = viewModel.items.filter { !$0.belongsToLeft && !$0.row.pendingConfirmation && ($0.hasUnread || $0.row.manuallyMarkedUnread) }
        case .left:
            base = (viewModel.items + viewModel.archivedItems).filter(\.belongsToLeft)
        }
        let baseIDs = Set(base.map(\.id))
        let retained = selectionMode ? (viewModel.items + viewModel.archivedItems).filter {
            bulkLeave.retainedIDs.contains($0.id) && !baseIDs.contains($0.id)
        } : []
        return (base + retained).filter {
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
        viewModel?.retainDestination(groupIdHex: item.id)
        exitSearch()
        path.append(
            ChatNavigationTarget(
                groupIdHex: item.id,
                messageIdHex: item.firstUnreadMessageIdHex,
                unreadMessageIdHex: item.firstUnreadMessageIdHex,
                performanceTicket: appState.productAnalytics.ticket()
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

        ForEach(actions) { action in
            WNSwipeActionButton(
                title: action.title,
                systemImage: action.systemImage,
                tint: action.tint
            ) {
                perform(action, on: item)
            }
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

        ForEach(actions) { action in
            WNSwipeActionButton(
                title: action.title,
                systemImage: action.systemImage,
                tint: action.tint
            ) {
                perform(action, on: item)
            }
        }
    }

    @MainActor
    private func perform(
        _ action: ChatListSwipeAction,
        on item: ChatsListViewModel.Item
    ) {
        switch action {
        case .read:
            Task { await markRead(item) }
        case .unread:
            Task { await markUnread(item) }
        case .pin:
            Task { await setPinned(item, pinned: true) }
        case .unpin:
            Task { await setPinned(item, pinned: false) }
        case .mute:
            pendingMute = muteTarget(groupIds: [item.id], fromSelection: false)
        case .unmute:
            if let target = muteTarget(groupIds: [item.id], fromSelection: false) {
                Task { await updateMute(.unmute, target: target) }
            }
        case .archive:
            Task { await setArchived(groupIdHex: item.id, archived: true) }
        case .unarchive:
            Task { await setArchived(groupIdHex: item.id, archived: false) }
        case .leave:
            let target = ChatListLeavePresentation.Target(
                groupIdHex: item.id,
                title: item.title
            )
            Task { await prepareLeave(target) }
        case .delete:
            // Never give this a destructive role: SwiftUI would optimistically
            // remove the row before the confirmation dialog has resolved.
            pendingSingleDelete = LocalDeleteTarget(id: item.id, title: item.title)
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

        let unreadItems: [ChatsListViewModel.Item]
        do { unreadItems = try await viewModel.allUnreadItems() }
        catch { presentMarkReadFailure(); return }
        var hadFailure = false
        for item in unreadItems {
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

    private struct BulkLeaveBlocked: Error {
        let title: String
        let message: String
    }

    private func leaveContextIsCurrent(_ context: ChatLeaveOperation.Context) -> Bool {
        appState.activeAccountRef == context.accountRef
            && appState.runtimeGeneration == context.runtimeGeneration
            && appState.canUseRuntimeForLocalForegroundWork
    }

    private func confirmBulkLeave(_ request: BulkLeaveRequest) async -> String? {
        let context = request.context
        guard !selectionMutationInProgress, leaveContextIsCurrent(context) else { return nil }
        do {
            try await bulkLeave.prepare(context: context, targets: request.targets, isCurrent: {
                leaveContextIsCurrent(context)
            }) { target in
                let state = try await readLeaveState(groupIdHex: target.groupIdHex, context: context)
                if state.settledResult != nil { return false }
                guard state.canLeave else {
                    throw BulkLeaveBlocked(
                        title: L10n.formatted("Couldn't leave “%@”", target.title),
                        message: state.blockedMessage
                    )
                }
                return state.requiresSelfDemotion
            }
        } catch {
            guard !Task.isCancelled, leaveContextIsCurrent(context) else { return nil }
            Haptics.error()
            if let blocked = error as? BulkLeaveBlocked {
                return blocked.title + "\n" + blocked.message
            }
            return ChatListLeavePresentation.failureMessage
        }
        guard !Task.isCancelled,
              let confirmation = bulkLeave.confirmation,
              confirmation.context == context,
              confirmation.targets == request.targets,
              bulkLeave.approve(confirmation, isCurrent: leaveContextIsCurrent(context))
        else { return nil }
        guard let result = await bulkLeave.runApproved(isCurrent: {
            leaveContextIsCurrent(context)
        }, leave: { target in
            await performChatLeave(groupIdHex: target.groupIdHex, context: context)
        }) else { return nil }
        guard result.failedIDs.isEmpty else {
            Haptics.error()
            return L10n.plural("Couldn't leave %lld chats. Try again.", Int64(result.failedIDs.count))
        }
        Haptics.warning()
        return nil
    }

    private func readLeaveState(
        groupIdHex: String,
        context: ChatLeaveOperation.Context
    ) async throws -> ChatLeaveOperation.State {
        guard leaveContextIsCurrent(context), !Task.isCancelled else { throw CancellationError() }
        let client = try appState.currentMarmotClient()
        guard let row = try await client.chatListRow(accountRef: context.accountRef, groupIdHex: groupIdHex) else {
            throw CancellationError()
        }
        guard leaveContextIsCurrent(context), !Task.isCancelled else { throw CancellationError() }
        if !GroupManagementPresentation.isActiveChatListMember(row.selfMembership) {
            return .init(membershipEnded: true)
        }
        if row.leaveRequestPending { return .init(leaveRequestPending: true) }
        let state = try await client.groupManagementState(accountRef: context.accountRef, groupIdHex: groupIdHex)
        guard leaveContextIsCurrent(context), !Task.isCancelled else { throw CancellationError() }
        return .init(
            leaveRequestPending: state.leaveRequestPending,
            canLeave: GroupManagementPresentation.canLeave(state: state, fallbackIsLastAdmin: false),
            requiresSelfDemotion: GroupManagementPresentation.shouldSelfDemoteBeforeLeave(state: state),
            blockedMessage: GroupManagementPresentation.leaveHelpMessage(state: state, fallbackIsLastAdmin: false)
        )
    }

    private func performChatLeave(
        groupIdHex: String,
        context: ChatLeaveOperation.Context
    ) async -> ChatLeaveOperation.Result {
        var didLeave = false
        let result = await ChatLeaveOperation.perform(isCurrent: {
            leaveContextIsCurrent(context)
        }, readState: {
            try await readLeaveState(groupIdHex: groupIdHex, context: context)
        }, selfDemote: {
            _ = try await appState.currentMarmotClient().selfDemoteAdminDetailed(
                accountRef: context.accountRef, groupIdHex: groupIdHex
            )
        }, leave: {
            _ = try await appState.currentMarmotClient().leaveGroup(
                accountRef: context.accountRef, groupIdHex: groupIdHex
            )
            didLeave = true
        })
        guard leaveContextIsCurrent(context), !Task.isCancelled else { return .cancelled }
        switch result {
        case .left:
            if didLeave { viewModel?.markGroupLeft(groupIdHex: groupIdHex) }
            await viewModel?.refreshRow(groupIdHex: groupIdHex)
        case .pending:
            viewModel?.markGroupLeavePending(groupIdHex: groupIdHex)
            await viewModel?.refreshRow(groupIdHex: groupIdHex)
        case .failed, .blocked, .cancelled: break
        }
        guard leaveContextIsCurrent(context), !Task.isCancelled else { return .cancelled }
        return result
    }

    @MainActor
    private func prepareLeave(_ target: ChatListLeavePresentation.Target) async {
        guard let accountRef = appState.activeAccountRef,
              leaveActionState.beginPreparation(for: target)
        else { return }
        let context = ChatLeaveOperation.Context(accountRef: accountRef, runtimeGeneration: appState.runtimeGeneration)
        leaveConfirmationContext = nil
        var canConfirm = false
        defer { leaveActionState.finishPreparation(for: target, canPresentConfirmation: canConfirm) }
        do {
            let state = try await readLeaveState(groupIdHex: target.groupIdHex, context: context)
            guard leaveContextIsCurrent(context), !Task.isCancelled else { return }
            if let result = state.settledResult {
                if result == .pending { viewModel?.markGroupLeavePending(groupIdHex: target.groupIdHex) }
                await viewModel?.refreshRow(groupIdHex: target.groupIdHex)
                return
            }
            guard state.canLeave else {
                Haptics.error()
                appState.present(.error(ChatListLeavePresentation.failureTitle, message: state.blockedMessage))
                return
            }
            leaveConfirmationContext = context
            canConfirm = true
        } catch {
            guard leaveContextIsCurrent(context), !Task.isCancelled else { return }
            presentLeaveFailure()
        }
    }

    @MainActor
    private func startConfirmedLeave(_ target: ChatListLeavePresentation.Target) {
        guard let context = leaveConfirmationContext, leaveContextIsCurrent(context) else {
            leaveActionState.cancelConfirmation()
            leaveConfirmationContext = nil
            return
        }
        guard leaveActionState.beginConfirmedLeave(for: target) else { return }
        leaveConfirmationContext = nil
        Task { @MainActor in
            defer { leaveActionState.finishLeave(groupIdHex: target.groupIdHex) }
            switch await performChatLeave(groupIdHex: target.groupIdHex, context: context) {
            case .left, .pending:
                Haptics.warning()
            case .blocked(let message):
                Haptics.error()
                appState.present(.error(ChatListLeavePresentation.failureTitle, message: message))
            case .failed:
                presentLeaveFailure()
            case .cancelled:
                break
            }
        }
    }

    private func presentLeaveFailure() {
        Haptics.error()
        appState.present(.error(
            ChatListLeavePresentation.failureTitle,
            message: ChatListLeavePresentation.failureMessage
        ))
    }

    private func mutePicker(target: MuteTarget, item: ChatsListViewModel.Item) -> some View {
        ChatMutePicker(
            isPresented: Binding(
                get: { pendingMute?.id == target.id },
                set: { presented in
                    guard !presented, pendingMute?.id == target.id else { return }
                    pendingMute = nil
                }
            ),
            message: L10n.formatted("Choose how long to mute %@.", item.title)
        ) { duration in
            guard pendingMute?.id == target.id else { return }
            pendingMute = nil
            Task { await updateMute(.mute(duration), target: target) }
        }
    }

    private func muteTarget(groupIds: [String], fromSelection: Bool) -> MuteTarget? {
        guard !groupIds.isEmpty, !isUpdatingMutes,
              let accountRef = appState.activeAccountRef,
              appState.canUseRuntimeForLocalForegroundWork else { return nil }
        return MuteTarget(
            accountRef: accountRef, runtimeGeneration: appState.runtimeGeneration,
            groupIds: groupIds, fromSelection: fromSelection
        )
    }

    private func muteTargetIsCurrent(_ target: MuteTarget) -> Bool {
        appState.activeAccountRef == target.accountRef
            && appState.runtimeGeneration == target.runtimeGeneration
            && appState.canUseRuntimeForLocalForegroundWork
    }

    @MainActor
    private func updateMute(_ action: ChatMuteAction, target: MuteTarget) async {
        guard !isUpdatingMutes, muteTargetIsCurrent(target) else { return }
        isUpdatingMutes = true
        updatingChatIds.formUnion(target.groupIds)
        defer {
            isUpdatingMutes = false
            updatingChatIds.subtract(target.groupIds)
        }
        var failedIds = Set(target.groupIds)
        let now = Date.now
        do {
            let client = try appState.currentMarmotClient()
            for id in target.groupIds {
                guard !Task.isCancelled, muteTargetIsCurrent(target) else { return }
                do {
                    try await client.updateChatMute(action, accountRef: target.accountRef, groupIdHex: id, now: now)
                    failedIds.remove(id)
                } catch {
                    // Keep failed chats selected so the action can be retried.
                }
                guard muteTargetIsCurrent(target) else { return }
                await viewModel?.refreshRow(groupIdHex: id)
            }
        } catch { }
        guard !Task.isCancelled, muteTargetIsCurrent(target) else { return }
        if target.fromSelection {
            if failedIds.isEmpty {
                endSelectionMode()
            } else {
                selectedChatIds = failedIds
            }
        }
        if failedIds.isEmpty {
            Haptics.success()
        } else {
            presentChatMutationFailure(title: L10n.string("Couldn't update notifications"))
        }
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
                initialAvatarAsset: item.avatarAsset,
                initialAvatarSeed: item.selectedAvatar != nil ? item.avatarSeed : nil,
                initialOtherMember: item.directPeerAccountIdHex,
                initialMemberCount: item.isDirectMessage == true ? 2 : nil,
                initialLeaveRequestPending: item.leaveRequestPending,
                initialTargetMessageIdHex: target.messageIdHex,
                initialUnreadMessageIdHex: target.unreadMessageIdHex,
                initialAppState: appState,
                navigationStartedAt: target.openedAt,
                performanceTicket: target.performanceTicket,
                forwardDestinationProvider: {
                    try await viewModel.forwardDestinations(excludingGroupIdHex: target.groupIdHex)
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

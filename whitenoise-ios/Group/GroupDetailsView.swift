import SwiftUI
import UIKit
import MarmotKit

enum GroupDetailsConfirmation: Identifiable {
    case leave
    case deleteLocal
    case remove(GroupMemberDetailsFfi)
    case selfDemote
    case disband

    var id: String {
        switch self {
        case .leave:
            return "leave"
        case .deleteLocal:
            return "delete-local"
        case .remove(let member):
            return "remove-\(member.memberIdHex)"
        case .selfDemote:
            return "self-demote"
        case .disband:
            return "disband"
        }
    }
}

/// Full-page conversation details, pushed from the conversation header.
/// Direct messages and groups share one information architecture — identity,
/// actions, shared media, settings, people, technical details, destructive
/// actions — with contextual differences: a DM leads with the contact's
/// identity and shared groups, a group with its roster and admin editing.
struct GroupDetailsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: ConversationViewModel
    var openAddMembersOnAppear = false
    var onGroupChanged: (AppGroupRecordFfi) -> Void = { _ in }
    var onGroupLeft: (String) -> Void = { _ in }
    var onGroupDeleted: (String) -> Void = { _ in }

    @State private var model = GroupDetailsViewModel()
    @State private var sharedMediaGallery: MessageMediaGallery?
    /// Presents the tapped member contextually, with moderation scope.
    @State private var memberProfileTarget: MemberProfileTarget?
    @State private var memberSearchText = ""
    @State private var membersExpanded = false
    @State private var showTechnicalDetails = false
    @State private var showNotifications = false
    @State private var showMediaLibrary = false
    @State private var showRelays = false
    @State private var showContactProfile = false
    @State private var editingNickname = false
    @State private var nicknameDraft = ""
    @State private var showStartGroupWithContact = false
    @State private var showAddContactToGroup = false
    @State private var didOpenRequestedAddMembers = false
    @State private var memberProjectionCache = GroupMemberListProjectionCache()

    private var isAdmin: Bool {
        viewModel.isSelfAdmin && !viewModel.isGroupDisbandingOrDisbanded
    }
    private var isDirectMessage: Bool { viewModel.groupDisplay.isDirectMessage }
    private var memberCount: Int {
        viewModel.groupMemberDetails.isEmpty ? viewModel.members.count : viewModel.groupMemberDetails.count
    }

    var body: some View {
        @Bindable var model = model
        // @ObservationIgnored, so this never triggers a re-render; it guarantees
        // the model's conversation/onGroupChanged are set before any method runs.
        model.conversation = viewModel
        model.onGroupChanged = onGroupChanged
        model.onGroupLeft = onGroupLeft
        model.onGroupDeleted = onGroupDeleted
        return Form {
            if isDirectMessage {
                contactIdentitySection
            } else {
                groupIdentitySection
            }
            groupLifecycleSection
            actionsRowSection
            sharedMediaSection
            settingsSection
            if isDirectMessage {
                sharedGroupsSection
            } else {
                membersSection
                relaysSection
            }
            technicalDetailsSection
            destructiveActionsSection

            if appState.developerMode {
                Section {
                    NavigationLink {
                        ChatDeveloperToolsView(model: model, conversation: viewModel)
                    } label: {
                        Label("Chat Developer Tools", systemImage: "wrench.and.screwdriver")
                    }
                }
            }

            if let actionError = model.actionError {
                Section {
                    Label(actionError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .productScreen(.groupDetails)
        .navigationTitle(isDirectMessage ? Text("Chat Info") : Text("Group Info"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .navigationDestination(item: $memberProfileTarget) { target in
            // Resolve the live roster entry so promote/demote done from the
            // destination is reflected without reopening it.
            let member = viewModel.groupMemberDetails.first {
                $0.memberIdHex == target.member.memberIdHex
            } ?? target.member
            profileDestination(
                npub: member.npub,
                moderation: moderationContext(for: member)
            )
        }
        .navigationDestination(isPresented: $showContactProfile) {
            if let contactNpub {
                profileDestination(npub: contactNpub, moderation: nil)
            }
        }
        .sheet(isPresented: $showStartGroupWithContact) {
            if let contactAccountIdHex, let contactNpub {
                NewChatFlowView(initialGroupMembers: [
                    MemberRefFfi(
                        memberRef: contactNpub,
                        accountIdHex: contactAccountIdHex,
                        npub: contactNpub
                    )
                ])
                .appAppearance()
            }
        }
        .sheet(isPresented: $showAddContactToGroup) {
            if let contactNpub {
                AddToGroupSheet(
                    contactNpub: contactNpub,
                    contactName: contactTitle,
                    groups: model.addableGroups,
                    onAdded: {
                        await model.loadSharedGroups(using: appState, force: true)
                    }
                )
                .appAppearance()
            }
        }
        // Unwind every details-owned presentation when a chat navigation
        // posts; isPresented pushes otherwise re-assert over the new stack.
        .onChange(of: appState.pendingChatId) { _, pending in
            if pending != nil {
                showContactProfile = false
                showNotifications = false
                showMediaLibrary = false
                showRelays = false
                memberProfileTarget = nil
                showStartGroupWithContact = false
                showAddContactToGroup = false
            }
        }
        .navigationDestination(isPresented: $showNotifications) {
            ChatNotificationsView(model: model)
        }
        .navigationDestination(isPresented: $showMediaLibrary) {
            SharedMediaLibraryView(conversation: viewModel)
        }
        .navigationDestination(isPresented: $showRelays) {
            GroupRelaysView(relays: viewModel.group.relays)
        }
        .toolbar {
            if !isDirectMessage && isAdmin {
                ToolbarItem(placement: .topBarTrailing) {
                    editMenu
                }
            }
        }
        .alert(nicknameAlertTitle, isPresented: $editingNickname) {
            TextField(L10n.string("Nickname"), text: $nicknameDraft)
            Button(L10n.string("Save"), action: saveNickname)
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text("Only you see this on this device. Clearing it restores their profile name.")
        }
        .sheet(isPresented: $model.showAddMembers) {
            AddMembersSheet(
                normalize: { try await appState.currentMarmotClient().normalizeMemberRef(memberRef: $0) },
                onSubmit: { refs in try await model.invite(refs: refs, using: appState) },
                excludedAccountIds: AddMembersPresentation.excludedInviteAccountIds(
                    activeAccountIdHex: appState.activeAccount?.accountIdHex,
                    members: viewModel.members,
                    groupMemberDetails: viewModel.groupMemberDetails
                ),
                excludedMemberMessage: AddMembersPresentation.existingMemberMessage
            )
            .appAppearance()
        }
        .sheet(isPresented: $model.showGroupImageEditor) {
            GroupImageURLSheet(
                hasCurrentImage: viewModel.group.avatarUrl != nil || viewModel.group.imageHashHex != nil,
                currentURL: ContentSanitizer.imageURL(viewModel.group.avatarUrl),
                currentGroupIdHex: viewModel.group.groupIdHex,
                currentImageHashHex: viewModel.group.imageHashHex,
                onSave: GroupImageSaveSubmitter(progressReporting: { draft, onProgress in
                    try await model.updateGroupImage(
                        draft: draft,
                        using: appState,
                        onProgress: onProgress
                    )
                })
            )
            .appAppearance()
        }
        .sheet(isPresented: $model.showRetentionEditor) {
            GroupRetentionEditorSheet(
                currentSeconds: viewModel.group.disappearingMessageSecs,
                onSubmit: GroupRetentionSubmitter { seconds in
                    await model.updateRetention(seconds: seconds, using: appState)
                }
            )
            .appAppearance()
        }
        .sheet(isPresented: $model.showProfileEditor) {
            NavigationStack {
                Form {
                    Section {
                        TextField("Group name", text: $model.renameDraft)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                        TextField(
                            "Description",
                            text: $model.descriptionDraft,
                            axis: .vertical
                        )
                        .lineLimit(4...8)
                    } footer: {
                        Text("Everyone in the group will see this name and description. Leave the description blank to remove it.")
                    }
                }
                .navigationTitle("Edit Group Info")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { model.showProfileEditor = false }
                            .disabled(model.membershipActionInFlight)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task {
                                if await model.updateProfile(using: appState) {
                                    model.showProfileEditor = false
                                }
                            }
                        }
                        .disabled(
                            model.membershipActionInFlight
                                || Self.validatedGroupName(model.renameDraft) == nil
                        )
                    }
                }
                .interactiveDismissDisabled(model.membershipActionInFlight)
            }
            .appAppearance()
        }
        .fullScreenCover(item: $model.pendingConfirmation) { confirmation in
            fullScreenConfirmation(for: confirmation)
                .appAppearance()
        }
        .fullScreenCover(item: $sharedMediaGallery) { gallery in
            MessageMediaFullscreenGalleryView(
                gallery: gallery,
                onLoadMedia: mediaLoader,
                forwardingContext: MediaForwardingContext(
                    viewModel: viewModel,
                    destinationProvider: { try await viewModel.forwardDestinations() }
                ),
                onGoToMessage: { messageId in
                    appState.presentChat(
                        groupIdHex: viewModel.group.groupIdHex,
                        messageIdHex: messageId
                    )
                },
                onDismiss: { sharedMediaGallery = nil }
            )
        }
        .task(id: appState.developerMode) {
            await model.refreshGroupManagementAndNotify()
            await model.refreshVisibleDebugState(using: appState)
        }
        .task(id: viewModel.groupMlsRefreshGeneration) {
            await model.refreshVisibleDebugState(using: appState)
        }
        .task(id: viewModel.group.groupIdHex) {
            if openAddMembersOnAppear, !didOpenRequestedAddMembers, isAdmin, !isDirectMessage {
                didOpenRequestedAddMembers = true
                model.showAddMembers = true
            }
            model.loadMuteState(using: appState)
            await model.loadSharedMedia(using: appState)
            await model.loadSharedGroups(using: appState)
        }
        .refreshable {
            await model.loadSharedMedia(using: appState, force: true)
            await model.loadSharedGroups(using: appState, force: true)
        }
    }

    // MARK: - Navigation hooks

    /// Details is pushed over the conversation; search lives in the
    /// conversation chrome, so pop back and activate it there.
    private func openConversationSearch() {
        dismiss()
        viewModel.search.activate()
    }

    private func openChat(_ groupIdHex: String) {
        DeferredChatPresentation.present(
            groupIdHex: groupIdHex,
            using: appState,
            dismissFirst: dismiss
        )
    }

    private var mediaLoader: ConversationMediaLoader {
        ConversationMediaLoader { media in
            try await viewModel.data(for: media)
        }
    }

    // MARK: - Confirmations

    @ViewBuilder
    private func fullScreenConfirmation(for confirmation: GroupDetailsConfirmation) -> some View {
        switch confirmation {
        case .leave:
            FullScreenConfirmationDialog(
                title: isDirectMessage ? L10n.string("Leave this chat?") : L10n.string("Leave this group?"),
                message: GroupManagementPresentation.leaveConfirmationMessage(state: viewModel.managementState),
                systemImage: "rectangle.portrait.and.arrow.right",
                destructiveTitle: "Leave",
                onConfirm: {
                    model.pendingConfirmation = nil
                    Task { await model.leave(using: appState, dismiss: { dismiss() }) }
                },
                onCancel: { model.pendingConfirmation = nil }
            )
        case .deleteLocal:
            FullScreenConfirmationDialog(
                title: "Delete local copy?",
                message: "This removes the local history from this device. It won't send a leave proposal.",
                systemImage: "trash",
                destructiveTitle: "Delete Local Copy",
                onConfirm: {
                    model.pendingConfirmation = nil
                    Task { await model.deleteLocal(using: appState, dismiss: { dismiss() }) }
                },
                onCancel: { model.pendingConfirmation = nil }
            )
        case .remove(let member):
            FullScreenConfirmationDialog(
                title: "Remove this member?",
                message: "They'll stop receiving new messages in this group.",
                systemImage: "person.crop.circle.badge.minus",
                destructiveTitle: "Remove from Group",
                onConfirm: {
                    model.pendingConfirmation = nil
                    Task { await model.remove(member: member, using: appState) }
                },
                onCancel: { model.pendingConfirmation = nil }
            )
        case .selfDemote:
            FullScreenConfirmationDialog(
                title: "Step down as admin?",
                message: "You'll stay in the group, but another admin will need to restore your admin status.",
                systemImage: "star.slash",
                destructiveTitle: "Step Down",
                onConfirm: {
                    model.pendingConfirmation = nil
                    Task { await model.selfDemote(using: appState) }
                },
                onCancel: { model.pendingConfirmation = nil }
            )
        case .disband:
            FullScreenConfirmationDialog(
                title: L10n.string("End this group?"),
                message: GroupManagementPresentation.disbandConfirmationMessage,
                systemImage: "xmark.circle",
                destructiveTitle: L10n.string("End Group"),
                onConfirm: {
                    model.pendingConfirmation = nil
                    Task { await model.endGroup(using: appState) }
                },
                onCancel: { model.pendingConfirmation = nil }
            )
        }
    }

    // MARK: - Identity

    private var groupIdentitySection: some View {
        let groupDisplay = viewModel.groupDisplay
        let displayTitle = viewModel.displayTitle(for: groupDisplay)
        return Section {
            VStack(spacing: 10) {
                Group {
                    if isAdmin {
                        Button {
                            model.showGroupImageEditor = true
                        } label: {
                            groupAvatar(groupDisplay: groupDisplay, displayTitle: displayTitle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            !hasGroupImage
                                ? L10n.string("Set group image")
                                : L10n.string("Edit group image")
                        )
                    } else {
                        groupAvatar(groupDisplay: groupDisplay, displayTitle: displayTitle)
                    }
                }

                Text(displayTitle)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(L10n.plural("Group · %lld members", Int64(memberCount)))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let description = ContentSanitizer.multilineText(
                    viewModel.group.description,
                    maxLength: ContentSanitizer.maxGroupDescriptionLength
                ) {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                } else if isAdmin {
                    Button {
                        model.prepareProfileDrafts()
                        model.showProfileEditor = true
                    } label: {
                        Text("Add Description")
                            .font(.callout)
                    }
                    .disabled(model.membershipActionInFlight)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }

    private func groupAvatar(groupDisplay: GroupDisplay.Resolved, displayTitle: String) -> some View {
        GroupAvatarBubble(
            groupIdHex: viewModel.group.groupIdHex,
            imageHashHex: viewModel.group.pendingConfirmation ? nil : viewModel.group.imageHashHex,
            seed: GroupDisplay.avatarSeed(for: groupDisplay),
            title: displayTitle,
            pictureURL: viewModel.group.imageHashHex != nil
                && ContentSanitizer.imageURL(viewModel.group.avatarUrl) == nil
                ? nil
                : GroupDisplay.avatarURL(for: groupDisplay, appState: appState)
        )
        .frame(width: 104, height: 104)
    }

    private var contactIdentitySection: some View {
        Section {
            VStack(spacing: 10) {
                Button {
                    showContactProfile = true
                } label: {
                    VStack(spacing: 10) {
                        AvatarBubble(
                            seed: contactAccountIdHex ?? viewModel.group.groupIdHex,
                            title: contactTitle,
                            pictureURL: contactAccountIdHex.flatMap { appState.avatarURL(forAccountIdHex: $0) }
                        )
                        .frame(width: 104, height: 104)

                        Text(contactTitle)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(contactNpub == nil)
                .accessibilityLabel(L10n.formatted("Show profile for %@", contactTitle))

                // When a private nickname overrides the header, keep the real
                // profile name visible so the override is never confused for
                // the contact's published name.
                if nickname != nil, let profileName {
                    Text(L10n.formatted("Name from profile: %@", profileName))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let contactNip05 {
                    Text(contactNip05)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let npub = contactNpub {
                    CopyableValueChip(
                        display: IdentityFormatter.short(npub, head: 12, tail: 10),
                        copyValue: npub,
                        copiedToastTitle: L10n.string("npub")
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Actions

    private var actionsRowSection: some View {
        Section {
            HStack(spacing: 12) {
                if isDirectMessage {
                    DetailsActionButton(
                        title: "About",
                        systemImage: "person.crop.circle",
                        isDisabled: contactNpub == nil,
                        appearance: .circular,
                        action: { showContactProfile = true }
                    )
                }
                DetailsActionButton(
                    title: model.isMuted ? "Unmute" : "Mute",
                    systemImage: model.isMuted ? "bell.fill" : "bell.slash",
                    appearance: .circular,
                    action: { model.setMuted(!model.isMuted, using: appState) }
                )
                DetailsActionButton(
                    title: "Disappearing",
                    systemImage: "timer",
                    isDisabled: !isAdmin || model.membershipActionInFlight,
                    appearance: .circular,
                    action: { model.showRetentionEditor = true }
                )
                DetailsActionButton(
                    title: "Search",
                    systemImage: "magnifyingglass",
                    appearance: .circular,
                    action: openConversationSearch
                )
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private var editMenu: some View {
        Menu {
            Button {
                model.prepareProfileDrafts()
                model.showProfileEditor = true
            } label: {
                Label("Edit Group Info", systemImage: "pencil")
            }
            Button {
                model.showGroupImageEditor = true
            } label: {
                Label(
                    hasGroupImage ? L10n.string("Edit Image") : L10n.string("Set Image"),
                    systemImage: "photo"
                )
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(model.membershipActionInFlight)
        .accessibilityLabel("Edit group")
    }

    // MARK: - Shared media

    private var sharedMediaSection: some View {
        GroupSharedMediaSection(
            records: model.sharedMediaRecords,
            isLoading: model.isLoadingSharedMedia,
            error: model.sharedMediaError,
            onRetry: {
                Task { await model.loadSharedMedia(using: appState, force: true) }
            },
            onLoadMedia: mediaLoader,
            onOpenGallery: { gallery in
                sharedMediaGallery = gallery
            },
            onSeeAll: { showMediaLibrary = true }
        )
    }

    // MARK: - Settings

    private var settingsSection: some View {
        Section {
            if isAdmin {
                Button {
                    model.showRetentionEditor = true
                } label: {
                    settingsRow(title: "Disappearing messages", systemImage: "timer") {
                        HStack(spacing: 6) {
                            Text(GroupSystemEventPresentation.retentionSettingLabel(
                                seconds: viewModel.group.disappearingMessageSecs
                            ))
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.membershipActionInFlight)
            } else {
                settingsRow(title: "Disappearing messages", systemImage: "timer") {
                    Text(GroupSystemEventPresentation.retentionSettingLabel(
                        seconds: viewModel.group.disappearingMessageSecs
                    ))
                }
            }

            Button {
                showNotifications = true
            } label: {
                settingsRow(title: "Notifications", systemImage: "bell") {
                    HStack(spacing: 6) {
                        Text(notifyModeSummary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)

            if isDirectMessage {
                Button(action: beginEditingNickname) {
                    settingsRow(title: "Nickname", systemImage: "pencil") {
                        HStack(spacing: 6) {
                            Text(nickname ?? L10n.string("None"))
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canEditNickname)
            }

            Button {
                Task { await model.setArchived(!viewModel.group.archived, using: appState) }
            } label: {
                settingsRow(
                    title: viewModel.group.archived ? "Unarchive" : "Archive",
                    systemImage: viewModel.group.archived ? "tray.and.arrow.up" : "archivebox"
                ) {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
            .disabled(model.membershipActionInFlight)
        } header: {
            Text("Settings")
        } footer: {
            Text("Archiving hides the chat from your main list. It doesn't notify anyone.")
        }
    }

    private func settingsRow(
        title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder value: () -> some View
    ) -> some View {
        LabeledContent {
            value()
        } label: {
            Label(title, systemImage: systemImage)
        }
        .contentShape(.rect)
    }

    // MARK: - People

    @ViewBuilder
    private var sharedGroupsSection: some View {
        if let contactAccountIdHex, let contactNpub {
            GroupsInCommonSection(
                contactAccountIdHex: contactAccountIdHex,
                contactNpub: contactNpub,
                contactName: contactTitle,
                sharedGroups: model.sharedGroups,
                addableGroups: model.addableGroups,
                onOpenChat: openChat,
                onStartGroup: { showStartGroupWithContact = true },
                onAddToGroup: { showAddContactToGroup = true }
            )
        }
    }

    private var membersSection: some View {
        let details = viewModel.groupMemberDetails
        let projection = memberProjectionCache.projection(
            members: details,
            profileGeneration: appState.profileRefreshGeneration,
            resolveName: { member in
                GroupMemberDetailsPresentation.displayName(for: member, appState: appState)
            }
        )
        let filtered = GroupMemberOrdering.filtered(
            projection.orderedMembers,
            query: memberSearchText,
            namesByMemberId: projection.namesByMemberId
        )
        let isSearching = !memberSearchText.trimmingCharacters(in: .whitespaces).isEmpty
        let visible = GroupMemberOrdering.visible(
            filtered,
            isSearching: isSearching,
            isExpanded: membersExpanded
        )
        return Section {
            if GroupManagementPresentation.canInvite(
                state: viewModel.managementState,
                fallbackIsAdmin: isAdmin
            ) {
                Button {
                    model.showAddMembers = true
                } label: {
                    Label("Add People", systemImage: "person.badge.plus")
                }
                .disabled(model.membershipActionInFlight)
            }

            if details.count > GroupMemberOrdering.previewCount {
                memberSearchField
            }

            if details.isEmpty {
                ForEach(viewModel.members, id: \.memberIdHex) { member in
                    GroupMemberRow(member: member, isAdmin: viewModel.isAdmin(member))
                }
            } else if filtered.isEmpty {
                Text("No members match your search.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visible, id: \.memberIdHex) { member in
                    if member.isSelf {
                        // Your own row is informational; your controls live in
                        // the destructive section and Settings.
                        GroupMemberDetailsRow(member: member)
                    } else {
                        Button {
                            memberProfileTarget = MemberProfileTarget(member: member)
                        } label: {
                            GroupMemberDetailsRow(member: member)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            swipeActions(for: member)
                        }
                    }
                }
                if !isSearching, !membersExpanded, filtered.count > GroupMemberOrdering.previewCount {
                    Button {
                        membersExpanded = true
                    } label: {
                        Text(L10n.plural("See all %lld members", Int64(filtered.count)))
                    }
                }
            }
        } header: {
            Text(L10n.plural("%lld members", Int64(memberCount)))
        } footer: {
            if !GroupManagementPresentation.canInvite(
                state: viewModel.managementState,
                fallbackIsAdmin: isAdmin
            ) {
                Text("Only admins can add or manage members.")
            }
        }
    }

    private var memberSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search members", text: $memberSearchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !memberSearchText.isEmpty {
                Button {
                    memberSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear member search")
            }
        }
    }

    // MARK: - Technical details

    private var relaysSection: some View {
        Section {
            Button {
                showRelays = true
            } label: {
                LabeledContent {
                    HStack(spacing: 6) {
                        Text(GroupRelaysPresentation.summary(for: viewModel.group.relays))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                } label: {
                    Label("Relays", systemImage: "network")
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } header: {
            Text("Advanced")
        }
    }

    private var technicalDetailsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showTechnicalDetails) {
                copyableDeveloperValueRow(title: "Group ID", value: viewModel.group.groupIdHex)
            } label: {
                Text("Group Details")
            }
        }
    }

    // MARK: - Destructive actions

    @ViewBuilder
    private var groupLifecycleSection: some View {
        switch GroupManagementPresentation.disbandStatus(
            group: viewModel.group,
            state: viewModel.managementState
        ) {
        case .none:
            EmptyView()
        case .pending:
            Section("Group Status") {
                HStack(alignment: .top, spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ending group…")
                            .font(.body.weight(.medium))
                        Text("Everyone is being removed. Messaging and group changes are disabled while the final update is processed.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .failed(let reason):
            Section("Group Status") {
                Label(
                    GroupManagementPresentation.disbandFailureMessage(reason),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                Button("Dismiss") {
                    Task { await model.acknowledgeDisbandFailure(using: appState) }
                }
                .disabled(model.membershipActionInFlight)
            }
        case .disbanded:
            Section("Group Status") {
                Label("Group ended", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                Text("This group was permanently disbanded. No one can send new messages or make group changes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var destructiveActionsSection: some View {
        Section {
            if GroupManagementPresentation.shouldShowEndGroup(
                state: viewModel.managementState
            ) {
                Button(role: .destructive) {
                    model.pendingConfirmation = .disband
                } label: {
                    Label("End Group", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(
                    !GroupManagementPresentation.canEndGroup(
                        state: viewModel.managementState
                    ) || model.membershipActionInFlight
                )
            }

            if !isDirectMessage, shouldShowSelfDemoteAction {
                Button(role: .destructive) {
                    model.pendingConfirmation = .selfDemote
                } label: {
                    Label("Step Down as Admin", systemImage: "star.slash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!canSelfDemoteAction || model.membershipActionInFlight)
            }

            if !viewModel.isGroupDisbanding {
                if viewModel.leaveRequestPending {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(GroupManagementPresentation.leavingGroupComposerMessage)
                            .foregroundStyle(.secondary)
                    }
                } else if viewModel.canSendMessages {
                    Button(role: .destructive) {
                        model.pendingConfirmation = .leave
                    } label: {
                        Label(
                            isDirectMessage ? L10n.string("Leave Chat") : L10n.string("Leave Group"),
                            systemImage: "rectangle.portrait.and.arrow.right"
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        !GroupManagementPresentation.canLeave(
                            state: viewModel.managementState,
                            fallbackIsLastAdmin: viewModel.isLastAdmin
                        ) || model.membershipActionInFlight
                    )
                } else {
                    Button(role: .destructive) {
                        model.pendingConfirmation = .deleteLocal
                    } label: {
                        Label("Delete Local Copy", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.membershipActionInFlight)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let blocker = GroupManagementPresentation.disbandBlockerMessage(
                    state: viewModel.managementState
                ) {
                    Text(blocker)
                }
                if viewModel.leaveRequestPending {
                    Text(GroupManagementPresentation.leavingGroupComposerMessage)
                } else if let leaveFooter = GroupManagementPresentation.leaveFooter(
                    state: viewModel.managementState,
                    fallbackIsLastAdmin: viewModel.isLastAdmin
                ), viewModel.canSendMessages {
                    Text(leaveFooter)
                } else if viewModel.isGroupDisbanded {
                    Text("Deletes this chat's local history from this device.")
                }
            }
        }
    }

    private var hasGroupImage: Bool {
        viewModel.group.avatarUrl != nil || viewModel.group.imageHashHex != nil
    }

    private var shouldShowSelfDemoteAction: Bool {
        isAdmin || viewModel.managementState?.requiresSelfDemoteBeforeLeave == true
    }

    private var canSelfDemoteAction: Bool {
        if GroupManagementPresentation.canSelfDemote(state: viewModel.managementState) { return true }
        return viewModel.managementState == nil && isAdmin && !viewModel.isLastAdmin
    }

    private func copyableDeveloperValueRow(title: String, value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            Haptics.selection()
            appState.present(.success(L10n.string("Copied to clipboard"), message: title))
        } label: {
            LabeledContent(title) {
                HStack(spacing: 6) {
                    Text(value)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(L10n.formatted("Copies %@", title))
    }

    // MARK: - Member actions

    private func profileDestination(npub: String, moderation: ProfileModerationContext?) -> some View {
        ProfileContentView(npub: npub, moderation: moderation)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
    }

    private struct MemberProfileTarget: Identifiable, Hashable {
        let member: GroupMemberDetailsFfi
        var id: String { member.memberIdHex }
    }

    /// Moderation scope for the contextual profile sheet, built from the
    /// live management state each presentation. Self-demote stays in the
    /// destructive section, not on another member's profile.
    private func moderationContext(for member: GroupMemberDetailsFfi) -> ProfileModerationContext? {
        let actions = memberActions(for: member).filter { $0 != .selfDemote }
        guard !actions.isEmpty else { return nil }
        return ProfileModerationContext(
            actions: actions,
            isAdmin: member.isAdmin,
            isBusy: model.membershipActionInFlight,
            onPromote: { Task { await model.setAdmin(member: member, admin: true, using: appState) } },
            onDemote: { Task { await model.setAdmin(member: member, admin: false, using: appState) } },
            onRemove: { Task { await model.remove(member: member, using: appState) } }
        )
    }

    @ViewBuilder
    private func swipeActions(for member: GroupMemberDetailsFfi) -> some View {
        let actions = memberActions(for: member)
        if actions.contains(.remove) {
            Button(role: .destructive) {
                model.pendingConfirmation = .remove(member)
            } label: {
                Label("Remove", systemImage: "person.crop.circle.badge.minus")
            }
        }
        if actions.contains(.demote) {
            Button {
                Task { await model.setAdmin(member: member, admin: false, using: appState) }
            } label: {
                Label("Remove Admin", systemImage: "star.slash")
            }
            .tint(.orange)
        }
        if actions.contains(.promote) {
            Button {
                Task { await model.setAdmin(member: member, admin: true, using: appState) }
            } label: {
                Label("Make Admin", systemImage: "star")
            }
            .tint(.orange)
        }
    }

    private func memberActions(for member: GroupMemberDetailsFfi) -> [GroupMemberManagementAction] {
        guard let action = viewModel.managementAction(for: member.memberIdHex) else { return [] }
        return GroupManagementPresentation.memberActions(for: action, state: viewModel.managementState)
    }

    // MARK: - Contact identity helpers

    private var contactAccountIdHex: String? { viewModel.otherMember }

    private var contactNpub: String? {
        viewModel.directMessageCounterpartNpub
            ?? contactAccountIdHex.map { appState.npub(forAccountIdHex: $0) }
    }

    private var contactTitle: String {
        guard let contactAccountIdHex else { return viewModel.displayTitle }
        return appState.knownDisplayName(forAccountIdHex: contactAccountIdHex)
            ?? appState.shortNpub(forAccountIdHex: contactAccountIdHex)
    }

    private var nickname: String? {
        contactAccountIdHex.flatMap { appState.contactNickname(forAccountIdHex: $0) }
    }

    private var profileName: String? {
        contactAccountIdHex.flatMap { appState.knownProfileDisplayName(forAccountIdHex: $0) }
    }

    private var contactNip05: String? {
        contactAccountIdHex.flatMap {
            ContentSanitizer.profileAddress(appState.profile(forAccountIdHex: $0)?.nip05)
        }
    }

    private var canEditNickname: Bool {
        contactAccountIdHex != nil && appState.activeAccountRef != nil
    }

    private var nicknameAlertTitle: String {
        nickname == nil ? L10n.string("Set nickname") : L10n.string("Edit nickname")
    }

    private var notifyModeSummary: String {
        switch model.notifyMode {
        case .all: L10n.string("On")
        case .mentionsOnly: L10n.string("Mentions")
        case .nothing: L10n.string("Muted")
        }
    }

    private func beginEditingNickname() {
        nicknameDraft = nickname ?? ""
        editingNickname = true
    }

    private func saveNickname() {
        guard let contactAccountIdHex else { return }
        appState.setContactNickname(nicknameDraft, forAccountIdHex: contactAccountIdHex)
        Haptics.selection()
    }

    /// A group rename must publish a non-empty sanitized name; an empty value
    /// would silently blank the shared group name (#80), and raw text would
    /// propagate spoofing characters to Marmot/relays (#195).
    static func validatedGroupName(_ draft: String) -> String? {
        ContentSanitizer.groupName(draft)
    }

    /// `nil` means "leave unchanged" to Marmot, while an empty string is the
    /// explicit remove-description sentinel. Keep that distinction at the UI
    /// boundary while still applying the shared peer-text sanitizer.
    static func normalizedGroupDescriptionForUpdate(_ draft: String) -> String {
        ContentSanitizer.multilineText(
            draft,
            maxLength: ContentSanitizer.maxGroupDescriptionLength
        ) ?? ""
    }

}

enum GroupDetailsActionError: Equatable, LocalizedError {
    case noActiveAccount
    case operationInFlight

    var errorDescription: String? {
        switch self {
        case .noActiveAccount:
            L10n.string("No active account is selected.")
        case .operationInFlight:
            L10n.string("Another group update is still in progress.")
        }
    }
}

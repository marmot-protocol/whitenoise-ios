import SwiftUI
import MarmotKit

nonisolated enum ProfilePrimaryActionPresentation {
    static func canMessage(
        resolvedAccountIdHex: String?,
        activeAccountIdHex: String?
    ) -> Bool {
        guard
            let resolvedAccountIdHex = resolvedAccountIdHex?.lowercased(),
            let activeAccountIdHex = activeAccountIdHex?.lowercased()
        else { return false }
        return resolvedAccountIdHex != activeAccountIdHex
    }
}

/// Moderation scope handed to the profile surface when it's opened from a
/// group's member list. Actions come from the live management state; the
/// mutations run through the details view model so permission enforcement
/// stays in the mutation path.
struct ProfileModerationContext {
    let actions: [GroupMemberManagementAction]
    let isAdmin: Bool
    let isBusy: Bool
    let onPromote: () -> Void
    let onDemote: () -> Void
    let onRemove: () -> Void
}

/// Reusable profile content: identity, copyable npub, messaging, following,
/// About, shared groups, group invitations, and contextual moderation.
/// Presented as a sheet in conversational contexts and pushed or sheeted as
/// a destination for deep links and QR scans.
struct ProfileContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let npub: String
    var moderation: ProfileModerationContext?
    /// Search results remain ephemeral in MDK, so the New Message preview
    /// carries their kind:0 metadata directly instead of promoting it into the
    /// local profile directory just to render this screen.
    var profileOverride: UserProfileMetadataFfi?
    var isSearchPreview = false
    var showsMessageAction = true
    var onFollowChanged: ((Bool) -> Void)?
    var onOpenConversation: ((String) -> Void)?

    @State private var model = ProfileViewModel()
    @State private var confirmingRemoval = false
    @State private var showAddToGroup = false
    @State private var blockedUsers = BlockedUsersModel()
    @State private var blockReload = 0

    var body: some View {
        List {
            headerSection

            if let prompt = model.startPrompt {
                StartChatPromptSection(
                    prompt: prompt,
                    onRetry: {
                        Task { await model.retryStart(using: appState, onOpen: openChat) }
                    },
                    onDismiss: { model.startPrompt = nil }
                )
            }

            aboutSection
            identityValuesSection
            profileActionsSection
            messageSection
            moderationSection
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(about == nil ? 24 : 8)
        .navigationTitle("User Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: resolutionKey) {
            await model.resolve(
                npub: npub,
                using: appState,
                refreshProfile: !isSearchPreview
            )
        }
        .task(id: "\(model.hex ?? "")/\(declaredNip05 ?? "")") { await model.verifyDeclaredNip05(declaredNip05) }
        .task(id: blockSubscriptionKey) {
            guard isBlockablePeer else { return }
            await blockedUsers.run(using: appState, target: npub)
        }
        .sheet(isPresented: $showAddToGroup) {
            AddToGroupSheet(
                contactNpub: displayReference ?? npub,
                contactName: title,
                groups: model.addableGroups,
                isLoading: model.directory.isLoading,
                loadError: model.directory.loadError,
                onRetry: { Task { await model.reloadGroups(using: appState, force: true) } },
                onAdded: { await model.reloadGroups(using: appState, force: true) }
            )
            .appAppearance()
        }
        .sheet(item: $model.conversationChooser) { chooser in
            ConversationChooserView(
                presentation: chooser,
                onOpen: { choice in
                    Task {
                        await model.openConversation(
                            choice,
                            using: appState,
                            onOpen: openChat
                        )
                    }
                },
                onStartNew: {
                    Task {
                        await model.startNewConversation(
                            using: appState,
                            onOpen: openChat
                        )
                    }
                },
                onCancel: { model.conversationChooser = nil }
            )
            .interactiveDismissDisabled(model.starter.isCreating)
            .appAppearance()
        }
    }

    // MARK: - Identity

    private var headerSection: some View {
        Section {
            ProfileIdentityHeader(
                name: title,
                npub: displayReference,
                nostrAddress: declaredNip05,
                isAddressVerified: model.verifiedNip05 == declaredNip05,
                bottomPadding: 0,
                showsIdentityValues: about == nil
            ) { size in
                AvatarBubble(
                    seed: model.hex ?? npub,
                    title: title,
                    pictureURL: ContentSanitizer.imageURL(effectiveProfile?.picture)
                )
                .frame(width: size, height: size)
            }
            if model.hex == nil {
                Label("Couldn't read this profile code.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    // MARK: - Actions

    @ViewBuilder
    private var profileActionsSection: some View {
        if canMessage {
            Section {
                if displayReference != nil {
                    GroupsInCommonRow(
                        sharedGroups: model.sharedGroups,
                        hasLoaded: model.groupsLoadState.hasLoaded,
                        loadError: model.directory.loadError,
                        onRetry: { Task { await model.reloadGroups(using: appState, force: true) } },
                        onOpenChat: openChat,
                        onAddToGroup: { showAddToGroup = true }
                    )
                    .disabled(isBlockedPeer)
                }
                if let hex = model.hex {
                    ProfileFollowButton(accountIdHex: hex, onChanged: onFollowChanged)
                        .disabled(isBlockedPeer)
                }
                BlockUserActions(model: blockedUsers) { blockReload += 1 }
                    .disabled(!isBlockablePeer)
            } header: {
                if moderation != nil { Text("Profile Actions") }
            }
        }
    }

    @ViewBuilder
    private var messageSection: some View {
        if showsMessageAction, canMessage, !isBlockedPeer {
            Section {
                WNButton(
                    title: "Message",
                    systemImage: "plus.bubble",
                    size: .standard,
                    isLoading: model.isPreparingConversationChoices || model.starter.isCreating
                ) {
                    Task {
                        await model.message(
                            npub: npub,
                            profile: effectiveProfile,
                            using: appState,
                            onOpen: openChat
                        )
                    }
                }
                .padding(.top, about == nil ? 0 : 16)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        if let about {
            Section {
                Text(about)
                    .font(.subheadline)
                    .italic()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .listRowBackground(Color(uiColor: .quaternarySystemFill).opacity(0.5))
        }
    }

    @ViewBuilder
    private var identityValuesSection: some View {
        if about != nil {
            Section {
                ProfileIdentityValues(
                    npub: displayReference,
                    nostrAddress: declaredNip05,
                    isAddressVerified: model.verifiedNip05 == declaredNip05
                )
                .padding(.bottom, 16)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    // MARK: - Moderation

    @ViewBuilder
    private var moderationSection: some View {
        if moderation?.actions.isEmpty == false {
            Section {
                moderationButtons
            } header: {
                Text("Group Actions")
            } footer: {
                if moderation?.isAdmin == true {
                    Text("This person is a group admin.")
                }
            }
        }
    }

    @ViewBuilder
    private var moderationButtons: some View {
        if let moderation, !moderation.actions.isEmpty {
            if moderation.actions.contains(.promote) {
                Button {
                    moderation.onPromote()
                    dismiss()
                } label: {
                    Label("Make Admin", systemImage: "star")
                }
                .disabled(moderation.isBusy)
            }
            if moderation.actions.contains(.demote) {
                Button {
                    moderation.onDemote()
                    dismiss()
                } label: {
                    Label("Remove Admin", systemImage: "star.slash")
                }
                .disabled(moderation.isBusy)
            }
            if moderation.actions.contains(.remove) {
                Button(role: .destructive) {
                    confirmingRemoval = true
                } label: {
                    Label("Remove from Group", systemImage: "person.crop.circle.badge.minus")
                }
                .disabled(moderation.isBusy)
                .confirmationDialog(
                    "Remove this member?",
                    isPresented: $confirmingRemoval,
                    titleVisibility: .visible
                ) {
                    Button("Remove from Group", role: .destructive) {
                        moderation.onRemove()
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("They'll stop receiving new messages in this group.")
                }
            }
        }
    }

    // MARK: - Blocking

    private var isBlockablePeer: Bool {
        BlockedUsersPresentation.canBlock(
            targetAccountIdHex: model.hex,
            localAccountIdHexes: appState.accounts.map(\.accountIdHex)
        )
    }

    /// Keep relationship rows visible but disable interaction while blocked;
    /// Message remains unavailable until the peer is unblocked.
    private var isBlockedPeer: Bool {
        isBlockablePeer && blockedUsers.targetIsBlocked
    }

    private var resolutionKey: String {
        "\(appState.activeAccountRef ?? "")/\(appState.runtimeGeneration)/\(appState.canUseRuntimeForForegroundWork)/\(npub)"
    }

    private var blockSubscriptionKey: String {
        "\(appState.activeAccountRef ?? "")/\(appState.runtimeGeneration)/\(appState.canUseRuntimeForForegroundWork)/\(npub)/\(isBlockablePeer)/\(blockReload)"
    }

    // MARK: - Helpers

    private func openChat(_ groupIdHex: String) {
        if let onOpenConversation {
            onOpenConversation(groupIdHex)
            return
        }
        DeferredChatPresentation.present(
            groupIdHex: groupIdHex,
            using: appState,
            dismissFirst: dismiss
        )
    }

    private var title: String {
        IdentityPresentation.text(
            accountIdHex: resolvedAccountIdHex,
            knownName: AppState.resolvedKnownDisplayName(
                profile: effectiveProfile,
                projectedName: projectedDisplayName,
                localAccountLabel: nil
            )
        )
    }

    private var declaredNip05: String? {
        ContentSanitizer.profileAddress(effectiveProfile?.nip05)
    }

    private var about: String? {
        ContentSanitizer.multilineText(
            effectiveProfile?.about,
            maxLength: ContentSanitizer.maxAboutLength
        )
    }

    private var effectiveProfile: UserProfileMetadataFfi? {
        if let profileOverride { return profileOverride }
        guard let hex = model.hex else { return nil }
        if isSearchPreview {
            return appState.cachedProfile(forAccountIdHex: hex)
        }
        return appState.profile(forAccountIdHex: hex)
    }

    private var projectedDisplayName: String? {
        guard let hex = model.hex else { return nil }
        if isSearchPreview {
            return appState.cachedKnownDisplayName(forAccountIdHex: hex)
        }
        return appState.knownDisplayName(forAccountIdHex: hex)
    }

    private var canMessage: Bool {
        ProfilePrimaryActionPresentation.canMessage(
            resolvedAccountIdHex: model.hex,
            activeAccountIdHex: appState.activeAccount?.accountIdHex
        )
    }

    /// The account this screen is about, whether it arrived as hex from a
    /// resolved lookup or as a bech32 reference from a link or QR scan.
    private var resolvedAccountIdHex: String? {
        model.hex ?? NostrProfileReference.pubkeyHex(fromBech32: npub)
    }

    private var displayReference: String? {
        IdentityPresentation.canonicalNpub(accountIdHex: resolvedAccountIdHex)
    }

}

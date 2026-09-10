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

nonisolated enum ProfileWebsitePresentation {
    struct Website: Equatable {
        let url: URL
        let displayText: String
    }

    static func website(_ raw: String?) -> Website? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= ContentSanitizer.maxImageURLLength,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.user == nil,
              components.password == nil,
              let host = components.host,
              !host.isEmpty,
              !ContentSanitizer.isPrivateOrLoopbackAddressLiteral(host),
              let url = components.url,
              case .confirmExternal = MessageLinkPolicy.action(for: url),
              let displayText = ContentSanitizer.relayDisplayLine(
                url.absoluteString,
                maxLength: 120
              )
        else { return nil }
        return Website(url: url, displayText: displayText)
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

/// Reusable profile content: identity, copyable npub, Message, private
/// nickname, About, shared groups, group actions, and contextual moderation.
/// Presented as a sheet in conversational contexts and pushed or sheeted as
/// a destination for deep links and QR scans.
struct ProfileContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let npub: String
    var moderation: ProfileModerationContext?
    /// Search results remain ephemeral in MDK, so the New Message preview
    /// carries their kind:0 metadata directly instead of promoting it into the
    /// local profile directory just to render this screen.
    var profileOverride: UserProfileMetadataFfi?
    var initialIsFollowing: Bool?
    var showsNewConversationActions = false
    /// Supplied by the host once the relationship mutation binding is
    /// available. Keeping it injected lets the profile UI land independently
    /// without simulating a successful network publish.
    var onLoadFollowing: (() async throws -> Bool)?
    var onSetFollowing: ((Bool) async throws -> Bool)?
    var onOpenConversation: ((String) -> Void)?

    @State private var model = ProfileViewModel()
    @State private var confirmingRemoval = false
    @State private var showStartGroup = false
    @State private var showAddToGroup = false
    @State private var pendingExternalWebsite: URL?

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

            primaryActionSection
            aboutSection
            identityValuesSection
            publicProfileSection
            moderationSection
            sharedGroupsSection
        }
        .listStyle(.insetGrouped)
        .task(id: npub) {
            await model.resolve(
                npub: npub,
                using: appState,
                refreshProfile: !showsNewConversationActions
            )
            if showsNewConversationActions {
                await model.prepareFollowStatus(
                    initialValue: initialIsFollowing,
                    load: onLoadFollowing
                )
            }
        }
        .task(id: appState.profileRefreshGeneration) {
            await model.refreshWebsite(using: appState)
        }
        .task(id: declaredNip05) { await model.verifyDeclaredNip05(declaredNip05) }
        .sheet(isPresented: $showStartGroup) {
            if let hex = model.hex, let displayReference {
                NewChatFlowView(initialGroupMembers: [
                    MemberRefFfi(
                        memberRef: displayReference,
                        accountIdHex: hex,
                        npub: displayReference
                    )
                ])
                .appAppearance()
            }
        }
        .sheet(isPresented: $showAddToGroup) {
            AddToGroupSheet(
                contactNpub: displayReference ?? npub,
                contactName: title,
                groups: model.addableGroups
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
        .alert(L10n.string("Open link?"), isPresented: websiteConfirmationPresented) {
            Button(L10n.string("Open")) {
                guard let url = pendingExternalWebsite else { return }
                pendingExternalWebsite = nil
                openURL(url)
            }
            Button("Cancel", role: .cancel) {
                pendingExternalWebsite = nil
            }
        } message: {
            if let url = pendingExternalWebsite {
                Text(MessageExternalLinkConfirmation.displayText(for: url))
            }
        }
    }

    // MARK: - Identity

    private var headerSection: some View {
        Section {
            VStack(spacing: 10) {
                if let bannerURL {
                    AsyncImage(url: bannerURL) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFill()
                        } else {
                            Color(.secondarySystemFill)
                                .overlay {
                                    if phase.error == nil {
                                        ProgressView()
                                    }
                                }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 112)
                    .clipShape(.rect(cornerRadius: 12))
                }

                AvatarBubble(
                    seed: model.hex ?? npub,
                    title: title,
                    pictureURL: ContentSanitizer.imageURL(effectiveProfile?.picture)
                )
                .frame(width: 104, height: 104)

                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                // When a private nickname overrides the header, keep the real
                // profile name visible as secondary text so the override is
                // never silently confused for the contact's published name.
                if nickname != nil, let profileName {
                    Text(L10n.formatted("Name from profile: %@", profileName))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if about == nil, let nip05 = declaredNip05 {
                    HStack(spacing: 5) {
                        Text(nip05)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if model.verifiedNip05 == nip05 {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Verified address")
                        }
                    }
                }

                if about == nil {
                    identityChip
                }

                if model.hex == nil {
                    Label("Couldn't read this profile code.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var primaryActionSection: some View {
        if canMessage {
            Section {
                HStack(spacing: 10) {
                    DetailsActionButton(
                        title: showsNewConversationActions ? "Start Conversation" : "Message",
                        systemImage: "message",
                        isLoading: model.isPreparingConversationChoices
                            || model.starter.isCreating
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
                    .foregroundStyle(.white)

                    if showsNewConversationActions {
                        DetailsActionButton(
                            title: model.isFollowing == true ? "Unfollow" : "Follow",
                            systemImage: model.isFollowing == true
                                ? "person.badge.minus"
                                : "person.badge.plus",
                            isDisabled: onSetFollowing == nil,
                            isLoading: model.isLoadingFollow || model.isUpdatingFollow
                        ) {
                            Task {
                                await model.toggleFollow(
                                    using: appState,
                                    action: onSetFollowing
                                )
                            }
                        }
                        .foregroundStyle(.white)
                    } else {
                        DetailsActionButton(
                            title: "New Group",
                            systemImage: "person.2.badge.plus"
                        ) {
                            showStartGroup = true
                        }
                        .accessibilityLabel(L10n.formatted("Create group with %@", title))

                        DetailsActionButton(
                            title: "Add to Group",
                            systemImage: "person.badge.plus",
                            isDisabled: model.addableGroups.isEmpty
                        ) {
                            showAddToGroup = true
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
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
                VStack(spacing: 8) {
                    if let nip05 = declaredNip05 {
                        HStack(spacing: 5) {
                            Text(nip05)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if model.verifiedNip05 == nip05 {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                                    .accessibilityLabel("Verified address")
                            }
                        }
                    }

                    identityChip
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder
    private var publicProfileSection: some View {
        if profileHandle != nil || lightningAddress != nil || website != nil {
            Section("Profile") {
                if let profileHandle {
                    LabeledContent("Name", value: profileHandle)
                }
                if let lightningAddress {
                    LabeledContent("Lightning address", value: lightningAddress)
                }
                if let website {
                    Button {
                        pendingExternalWebsite = website.url
                    } label: {
                        LabeledContent("Website") {
                            HStack(spacing: 6) {
                                Text(website.displayText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Image(systemName: "arrow.up.right.square")
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Groups in common

    @ViewBuilder
    private var sharedGroupsSection: some View {
        if let hex = model.hex, canMessage, let displayReference {
            GroupsInCommonSection(
                contactAccountIdHex: hex,
                contactNpub: displayReference,
                contactName: title,
                sharedGroups: model.sharedGroups,
                addableGroups: model.addableGroups,
                onOpenChat: openChat,
                showsActions: false,
                onStartGroup: { showStartGroup = true },
                onAddToGroup: { showAddToGroup = true }
            )
        }
    }

    // MARK: - Moderation

    @ViewBuilder
    private var moderationSection: some View {
        if moderation?.actions.isEmpty == false {
            Section {
                moderationButtons
            } header: {
                Text("Group Membership")
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
            knownName: nickname
                ?? AppState.resolvedKnownDisplayName(
                    profile: effectiveProfile,
                    projectedName: projectedDisplayName,
                    localAccountLabel: nil
                )
        )
    }

    private var nickname: String? {
        model.hex.flatMap { appState.contactNickname(forAccountIdHex: $0) }
    }

    private var profileName: String? {
        AppState.resolvedKnownDisplayName(
            profile: effectiveProfile,
            projectedName: nil,
            localAccountLabel: nil
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

    private var lightningAddress: String? {
        ContentSanitizer.profileAddress(effectiveProfile?.lud16)
    }

    private var website: ProfileWebsitePresentation.Website? {
        ProfileWebsitePresentation.website(model.website)
    }

    private var profileHandle: String? {
        ContentSanitizer.displayName(effectiveProfile?.name)
    }

    private var bannerURL: URL? {
        ContentSanitizer.imageURL(effectiveProfile?.banner)
    }

    private var effectiveProfile: UserProfileMetadataFfi? {
        if let profileOverride { return profileOverride }
        guard let hex = model.hex else { return nil }
        if showsNewConversationActions {
            return appState.cachedProfile(forAccountIdHex: hex)
        }
        return appState.profile(forAccountIdHex: hex)
    }

    private var projectedDisplayName: String? {
        guard let hex = model.hex else { return nil }
        if showsNewConversationActions {
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

    @ViewBuilder
    private var identityChip: some View {
        if let displayReference {
            CopyableValueChip(
                display: IdentityFormatter.short(displayReference, head: 12, tail: 10),
                copyValue: displayReference,
                copiedToastTitle: L10n.string("npub")
            )
        }
    }

    private var websiteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingExternalWebsite != nil },
            set: { if !$0 { pendingExternalWebsite = nil } }
        )
    }

}

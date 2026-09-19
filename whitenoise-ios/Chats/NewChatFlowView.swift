import SwiftUI
import UIKit
import MarmotKit

/// People-first entry point for starting a conversation. The root screen is
/// New Message (search known people or paste a profile); New Group pushes a
/// two-step picker → setup flow inside the same stack. The QR scanner and
/// self-code covers hang off the stack root so form re-renders can't dismiss
/// them.
struct NewChatFlowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Pre-seeds the group selection and opens directly on the picker step —
    /// the profile surface's "Start a Group with this person" entry point.
    var initialGroupMembers: [MemberRefFfi] = []

    @State private var model = NewChatFlowViewModel()
    @State private var path: [Route] = []
    @State private var scanTarget: ScanTarget?
    @State private var productCompose = ProductComposeObservation()
    @State private var didSeedInitialMembers = false

    enum Route: Hashable {
        case groupPicker
        case groupSetup
    }

    private enum ScanTarget: Identifiable {
        case message
        case groupPicker

        var id: String {
            switch self {
            case .message: "message"
            case .groupPicker: "group-picker"
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            NewMessageScreen(
                model: model,
                onScan: { scanTarget = .message },
                onOpen: open
            )
            .productScreen(.directory)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .groupPicker:
                    NewGroupPickerView(
                        model: model,
                        onScan: { scanTarget = .groupPicker },
                        onCancel: { dismiss() },
                        onNext: {
                            model.prewarmSelectedGroupMembers(using: appState)
                            path.append(.groupSetup)
                        }
                    )
                case .groupSetup:
                    NewGroupSetupView(model: model, onOpen: open)
                }
            }
        }
        .interactiveDismissDisabled(model.isBusy)
        .productScreen(.compose)
        .onAppear {
            productCompose.begin(using: appState.productAnalytics)
            guard !didSeedInitialMembers, !initialGroupMembers.isEmpty else { return }
            didSeedInitialMembers = true
            path = [.groupPicker]
            // Seeds ride the shared staging pipeline (Marmot normalization +
            // accountIdHex dedup) rather than raw construction.
            Task {
                let excluded = model.excludedAccountIds(using: appState)
                for member in initialGroupMembers {
                    let result = await AddMembersPresentation.normalizedMember(
                        member.memberRef,
                        normalize: { try await appState.currentMarmotClient().normalizeMemberRef(memberRef: $0) }
                    )
                    if case .normalized(let normalized) = result {
                        model.groupSelection.add(normalized, excludedAccountIds: excluded)
                    } else {
                        model.groupSelection.add(member, excludedAccountIds: excluded)
                    }
                }
            }
        }
        .fullScreenCover(item: $scanTarget) { target in
            ScannerSheet { raw in
                scanTarget = nil
                handleScan(raw, target: target)
            }
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
                            onOpen: open
                        )
                    }
                },
                onStartNew: {
                    Task {
                        await model.startNewConversation(
                            using: appState,
                            onOpen: open
                        )
                    }
                },
                onCancel: { model.conversationChooser = nil }
            )
            .interactiveDismissDisabled(model.starter.isCreating)
            .appAppearance()
        }
        .onDisappear {
            productCompose.end(using: appState.productAnalytics, temporarilyCovered: scanTarget != nil)
            model.messageUserSearch.cancel()
            model.cancelGroupMemberPrewarm()
        }
    }

    private func open(_ groupIdHex: String) {
        productCompose.complete()
        DeferredChatPresentation.present(
            groupIdHex: groupIdHex,
            using: appState,
            dismissFirst: dismiss
        )
    }

    /// A scanned code feeds the target screen's search field so the shared
    /// resolution pipeline (validation, preview row, self-exclusion) applies.
    private func handleScan(_ raw: String, target: ScanTarget) {
        guard AddMembersPresentation.memberRef(fromScannedPayload: raw) != nil else {
            Haptics.error()
            appState.present(.error(L10n.string("That QR code isn't a White Noise profile.")))
            return
        }
        Haptics.success()
        let query = target == .message ? model.messageQuery : model.groupQuery
        // The screens observe the text and run the resolution themselves.
        query.text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Search over known people, quick actions, and the paste-a-profile resolver.
struct NewMessageScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismissFlow
    @Bindable var model: NewChatFlowViewModel
    let onScan: () -> Void
    let onOpen: (String) -> Void
    @State private var profilePreview: ProfilePreview?

    private struct ProfilePreview: Hashable, Identifiable {
        let accountIdHex: String
        let npub: String
        let profile: UserProfileMetadataFfi?

        var id: String { accountIdHex }
    }

    var body: some View {
        @Bindable var query = model.messageQuery
        List {
            if let prompt = model.startPrompt {
                StartChatPromptSection(
                    prompt: prompt,
                    onRetry: {
                        Task { await model.retryStart(using: appState, onOpen: onOpen) }
                    },
                    onDismiss: { model.startPrompt = nil }
                )
            }

            quickActionsSection

            switch RecipientQueryMode.mode(
                isBlank: query.isBlank,
                isIdentifierQuery: query.isIdentifierQuery
            ) {
            case .browse:
                peopleSection
            case .resolve:
                RecipientResolutionSection(
                    query: model.messageQuery,
                    excludedAccountIds: model.excludedAccountIds(using: appState),
                    isBusy: model.isBusy,
                    creatingAccountIdHex: model.starter.creatingAccountIdHex,
                    showsDisclosureIndicator: true,
                    onRetry: { model.messageQuery.queryChanged(using: appState) },
                    onSelect: { resolved in
                        guard let npub = appState.npub(forAccountIdHex: resolved.accountIdHex) else { return }
                        profilePreview = ProfilePreview(
                            accountIdHex: resolved.accountIdHex,
                            npub: npub,
                            profile: appState.cachedProfile(forAccountIdHex: resolved.accountIdHex)
                        )
                    }
                )
            case .search:
                peopleSection
                RecipientUserSearchStatus(
                    isSearching: model.messageUserSearch.isSearching,
                    isIncomplete: model.messageUserSearch.isIncomplete,
                    didFail: model.messageUserSearch.didFail,
                    onRetry: { model.messageUserSearch.retry(using: appState) }
                )
            }
        }
        .listStyle(.insetGrouped)
        // A `Label` icon in a list row takes the accent colour, and the app
        // ships no accent asset, so the action rows render system blue. The
        // tint has to be pinned on the List — on the Section it never reaches
        // the rows.
        .tint(WNButton.Metrics.accent(for: colorScheme))
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("New Chat")
        .navigationBarTitleDisplayMode(.inline)
        // iOS 26 anchors a native `.searchable` field to the bottom of the
        // screen; below that floor `SearchFieldPlacement` has nothing there,
        // so the shared bottom bar stands in — and its ✕ is this screen's way
        // out, which is why there is no Cancel above.
        .safeAreaInset(edge: .bottom) {
            WNSearchBar(
                query: $query.text,
                prompt: "Name or npub",
                focusesOnAppear: false,
                onPaste: {
                    if let pasted = RecipientPasteboard.profileQuery(
                        from: UIPasteboard.general.string
                    ) {
                        model.messageQuery.text = pasted
                    }
                },
                onClose: { dismissFlow() }
            )
            .disabled(model.isBusy)
        }
        .task {
            await model.directory.load(using: appState)
            updateUserSearch()
        }
        .refreshable { await model.directory.load(using: appState, force: true) }
        .onChange(of: model.messageQuery.text) { _, _ in
            model.messageQuery.queryChanged(using: appState)
            updateUserSearch()
        }
        .onChange(of: appState.profileRefreshGeneration) { _, _ in
            model.directory.refreshSearchFields(using: appState)
        }
        .navigationDestination(item: $profilePreview) { preview in
            ProfileContentView(
                npub: preview.npub,
                profileOverride: preview.profile,
                isSearchPreview: true,
                onFollowChanged: { isFollowing in
                    model.messageUserSearch.setFollowStatus(
                        accountIdHex: preview.accountIdHex,
                        isFollowing: isFollowing
                    )
                },
                onOpenConversation: onOpen
            )
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var browseResults: [RecipientCandidate] {
        let known = RecipientSearch.browse(
            model.directory.candidates,
            query: model.messageQuery.text,
            excludedAccountIds: model.excludedAccountIds(using: appState),
            fields: { model.directory.matchFields(for: $0) }
        )
        return RecipientSearch.merge(
            known: known,
            discovered: model.messageUserSearch.candidates,
            excludedAccountIds: model.excludedAccountIds(using: appState)
        )
    }

    private func updateUserSearch() {
        model.messageUserSearch.update(
            query: model.messageQuery.text,
            isIdentifierQuery: model.messageQuery.isIdentifierQuery,
            using: appState
        )
    }

    private var quickActionsSection: some View {
        Section {
            // A link rather than a button, so the row carries the system
            // disclosure and push behaviour of the step it opens.
            NavigationLink(value: NewChatFlowView.Route.groupPicker) {
                Label("New Group", systemImage: "person.2")
            }
            .wnGroupedCardRow(.first)
            RecipientQuickActionRow(
                title: "Scan QR Code",
                systemImage: "qrcode.viewfinder",
                showsDisclosure: true,
                action: onScan
            )
            .wnGroupedCardRow(.last)
        }
        .disabled(model.isBusy)
    }

    private var peopleSection: some View {
        let candidates = browseResults
        return RecipientPeopleSection(
            state: .resolve(
                candidateCount: candidates.count,
                isLoadingDirectory: model.directory.isLoading,
                directoryLoadError: model.directory.loadError,
                isSearchingNetwork: model.messageUserSearch.isSearching,
                trimmedQuery: model.messageQuery.trimmedText
            ),
            candidates: candidates,
            roundsSectionCard: true,
            emptyDescription: "Paste an npub, scan a QR code, or share yours to start chatting.",
            onRetryLoad: {
                Task { await model.directory.load(using: appState, force: true) }
            },
            row: personRow
        )
    }

    private func personRow(_ candidate: RecipientCandidate) -> some View {
        Button {
            profilePreview = ProfilePreview(
                accountIdHex: candidate.accountIdHex,
                npub: candidate.npub,
                profile: candidate.searchProfile
                    ?? appState.cachedProfile(forAccountIdHex: candidate.accountIdHex)
            )
        } label: {
            RecipientRow(
                accountIdHex: candidate.accountIdHex,
                profileOverride: candidate.searchProfile,
                searchContext: RecipientSearch.resultContext(
                    for: candidate,
                    query: model.messageQuery.text
                )
            ) {
                if model.choosingAccountIdHex == candidate.accountIdHex
                    || model.starter.creatingAccountIdHex == candidate.accountIdHex {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
    }
}

/// Lightweight chooser for all active or archived two-person conversations
/// shared with one person. It stays outside a navigation container because the
/// sheet has no nested navigation state.
struct ConversationChooserView: View {
    @Environment(AppState.self) private var appState

    let presentation: ConversationChooserPresentation
    let onOpen: (ConversationChoice) -> Void
    let onStartNew: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.formatted(
                        "Conversations with %@",
                        presentation.recipientName
                    ))
                    .font(.title3.weight(.semibold))
                    Text("Choose a conversation to continue, or start a new one.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            List {
                Section {
                    ForEach(presentation.choices) { choice in
                        Button {
                            onOpen(choice)
                        } label: {
                            conversationRow(choice)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    Button(action: onStartNew) {
                        Label("Start new conversation", systemImage: "square.and.pencil")
                            .font(.body.weight(.medium))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func conversationRow(_ choice: ConversationChoice) -> some View {
        let isNamed = choice.name != nil
        let title = choice.name ?? L10n.string("Conversation")
        let groupAvatarURL = ContentSanitizer.imageURL(choice.avatarUrl)
        let pictureURL = groupAvatarURL
            ?? (isNamed
                ? nil
                : appState.avatarURL(forAccountIdHex: presentation.targetAccountIdHex))

        return HStack(spacing: 12) {
            GroupAvatarBubble(
                groupIdHex: choice.groupIdHex,
                imageHashHex: choice.imageHashHex,
                seed: isNamed ? choice.groupIdHex : presentation.targetAccountIdHex,
                title: isNamed ? title : presentation.recipientName,
                pictureURL: pictureURL
            )
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if choice.isArchived {
                        Text("Archived")
                    }
                    if choice.isArchived && choice.lastActivityAt > 0 {
                        Text(verbatim: "•")
                    }
                    if choice.lastActivityAt > 0 {
                        Text(RelativeTime.chatList(
                            Date(timeIntervalSince1970: TimeInterval(choice.lastActivityAt))
                        ))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
        .padding(.vertical, 2)
    }
}

/// Inline outcome card after a failed chat start: an invite prompt when the
/// recipient has no usable messaging setup, an error with retry otherwise.
struct StartChatPromptSection: View {
    let prompt: StartChatPrompt
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                switch prompt.kind {
                case .invite:
                    Label("Invite to White Noise", systemImage: "person.crop.circle.badge.plus")
                        .font(.headline)
                    Text(StartChatFailurePresentation.inviteDetail(recipientName: prompt.recipientName))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        ShareLink(item: StartChatFailurePresentation.inviteMessage()) {
                            Label("Share Invite", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Retry", action: onRetry)
                            .buttonStyle(.bordered)
                    }
                case .error(let message):
                    Label("Couldn't start chat", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Retry", action: onRetry)
                        .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
    }
}

/// Resolver row states for an identifier-shaped query, shared by New Message
/// and the group member picker.
struct RecipientResolutionSection: View {
    @Environment(AppState.self) private var appState
    let query: RecipientQueryModel
    let excludedAccountIds: Set<String>
    let isBusy: Bool
    var creatingAccountIdHex: String?
    var selectedAccountIds: Set<String> = []
    var showsDisclosureIndicator = false
    var excludedMessage: (String) -> String = { _ in AddMembersPresentation.selfRecipientMessage }
    let onRetry: () -> Void
    let onSelect: (ResolvedRecipient) -> Void

    var body: some View {
        Section {
            switch query.resolution {
            case .idle, .resolving:
                RecipientResolvingRow()
            case .resolved(let resolved):
                resolvedRow(resolved)
            case .noProfile:
                Label("No profile found for that address.", systemImage: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
            case .failed:
                Label("Couldn't check that address.", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
                Button("Retry", action: onRetry)
            case .invalid:
                Label(
                    L10n.string("Enter a valid npub, nprofile, hex public key, or name@domain address."),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func resolvedRow(_ resolved: ResolvedRecipient) -> some View {
        let normalized = resolved.accountIdHex.lowercased()
        if excludedAccountIds.contains(normalized) {
            Label(excludedMessage(normalized), systemImage: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.secondary)
        } else {
            Button {
                onSelect(resolved)
            } label: {
                RecipientRow(accountIdHex: resolved.accountIdHex) {
                    HStack(spacing: 8) {
                        if isVerified(resolved) {
                            Label("Verified", systemImage: "checkmark.seal.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Verified address")
                        }
                        if creatingAccountIdHex == resolved.accountIdHex {
                            ProgressView()
                        } else if selectedAccountIds.contains(normalized) {
                            RecipientSelectionIndicator(isSelected: true)
                        } else if showsDisclosureIndicator {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
    }

    /// Verified means the resolved profile *declares* the same NIP-05 address
    /// the query just resolved through — the declared identifier provably
    /// maps back to this pubkey.
    private func isVerified(_ resolved: ResolvedRecipient) -> Bool {
        guard let queried = resolved.queriedNip05 else { return false }
        let declared = ContentSanitizer.profileAddress(
            appState.profile(forAccountIdHex: resolved.accountIdHex)?.nip05
        )
        return declared == queried
    }
}

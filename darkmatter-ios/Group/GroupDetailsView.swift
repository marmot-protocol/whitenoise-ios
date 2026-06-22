import SwiftUI
import UIKit
import MarmotKit

private enum GroupDetailsConfirmation: Identifiable {
    case leave
    case remove(GroupMemberDetailsFfi)
    case selfDemote

    var id: String {
        switch self {
        case .leave:
            return "leave"
        case .remove(let member):
            return "remove-\(member.memberIdHex)"
        case .selfDemote:
            return "self-demote"
        }
    }
}

/// Inspector for a single group. Name, members + admin management,
/// invite/remove, archive, leave, and (in developer mode) MLS internals.
struct GroupDetailsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: ConversationViewModel
    var onGroupChanged: (AppGroupRecordFfi) -> Void = { _ in }

    @State private var showAddMembers = false
    @State private var showRename = false
    @State private var showGroupImageEditor = false
    @State private var renameDraft = ""
    @State private var actionError: String?
    @State private var mlsState: AppGroupMlsStateFfi?
    @State private var pushDebugInfo: GroupPushDebugInfoFfi?
    @State private var pushDebugError: String?
    @State private var pendingConfirmation: GroupDetailsConfirmation?
    @State private var membershipActionInFlight = false
    @State private var showRelays = false
    @State private var actionHelp: GroupActionHelp?
    @State private var isExportingTranscript = false
    @State private var transcriptExportURL: URL?
    @State private var showTranscriptShareSheet = false
    @State private var transcriptExportError: String?

    private var isAdmin: Bool { viewModel.isSelfAdmin }
    private var memberCount: Int {
        viewModel.groupMemberDetails.isEmpty ? viewModel.members.count : viewModel.groupMemberDetails.count
    }

    var body: some View {
        Form {
            headerSection
            membersSection
            infoSection
            groupActionsSection

            if appState.developerMode {
                transcriptExportSection
                developerSection
                pushNotificationsDeveloperSection
            }

            if let actionError {
                Section {
                    Label(actionError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $showAddMembers) {
            AddMembersSheet(
                normalize: { try await appState.currentMarmotClient().normalizeMemberRef(memberRef: $0) },
                onSubmit: { refs in try await invite(refs: refs) }
            )
            .appAppearance()
        }
        .sheet(isPresented: $showGroupImageEditor) {
            GroupImageURLSheet(initialURL: viewModel.group.avatarUrl) { url in
                try await updateGroupImage(url: url)
            }
            .appAppearance()
        }
        .alert("Group name", isPresented: $showRename) {
            TextField("Group name", text: $renameDraft)
            Button("Save") { Task { await rename() } }
                .disabled(Self.validatedGroupName(renameDraft) == nil)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Everyone in the group will see the new name.")
        }
        .fullScreenCover(item: $pendingConfirmation) { confirmation in
            fullScreenConfirmation(for: confirmation)
                .appAppearance()
        }
        .alert(actionHelp?.title ?? "", isPresented: actionHelpBinding) {
            Button("OK", role: .cancel) { actionHelp = nil }
        } message: {
            Text(actionHelp?.message ?? "")
        }
        .alert(
            "Export failed",
            isPresented: Binding(
                get: { transcriptExportError != nil },
                set: { if !$0 { transcriptExportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { transcriptExportError = nil }
        } message: {
            Text(transcriptExportError ?? "")
        }
        .sheet(isPresented: $showTranscriptShareSheet, onDismiss: cleanupTranscriptExportFile) {
            if let transcriptExportURL {
                ActivityShareSheet(items: [transcriptExportURL], onComplete: cleanupTranscriptExportFile)
            }
        }
        .task(id: appState.developerMode) {
            await refreshGroupManagementAndNotify()
            await refreshVisibleDebugState()
        }
        .task(id: viewModel.groupMlsRefreshGeneration) {
            await refreshVisibleDebugState()
        }
    }

    // MARK: - Sections

    private var actionHelpBinding: Binding<Bool> {
        Binding(
            get: { actionHelp != nil },
            set: { if !$0 { actionHelp = nil } }
        )
    }

    @ViewBuilder
    private func fullScreenConfirmation(for confirmation: GroupDetailsConfirmation) -> some View {
        switch confirmation {
        case .leave:
            FullScreenConfirmationDialog(
                title: "Leave this group?",
                message: GroupManagementPresentation.leaveConfirmationMessage(state: viewModel.managementState),
                systemImage: "rectangle.portrait.and.arrow.right",
                destructiveTitle: "Leave",
                onConfirm: {
                    pendingConfirmation = nil
                    Task { await leave() }
                },
                onCancel: { pendingConfirmation = nil }
            )
        case .remove(let member):
            FullScreenConfirmationDialog(
                title: "Remove this member?",
                message: "They'll stop receiving new messages in this group.",
                systemImage: "person.crop.circle.badge.minus",
                destructiveTitle: "Remove from Group",
                onConfirm: {
                    pendingConfirmation = nil
                    Task { await remove(member: member) }
                },
                onCancel: { pendingConfirmation = nil }
            )
        case .selfDemote:
            FullScreenConfirmationDialog(
                title: "Step down as admin?",
                message: "You'll stay in the group, but another admin will need to restore your admin status.",
                systemImage: "star.slash",
                destructiveTitle: "Step Down",
                onConfirm: {
                    pendingConfirmation = nil
                    Task { await selfDemote() }
                },
                onCancel: { pendingConfirmation = nil }
            )
        }
    }

    private var headerSection: some View {
        Section {
            HStack(spacing: 14) {
                AvatarBubble(
                    seed: GroupDisplay.avatarSeed(group: viewModel.group, otherMember: viewModel.otherMember, memberCount: memberCount),
                    title: viewModel.displayTitle,
                    pictureURL: GroupDisplay.avatarURL(group: viewModel.group, otherMember: viewModel.otherMember, memberCount: memberCount, appState: appState)
                )
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.displayTitle)
                        .font(.title3.weight(.semibold))
                    if let description = ProfileSanitizer.multilineText(
                        viewModel.group.description,
                        maxLength: ProfileSanitizer.maxGroupDescriptionLength
                    ) {
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 6)

            if isAdmin {
                Button {
                    renameDraft = ProfileSanitizer.groupName(viewModel.group.name) ?? ""
                    showRename = true
                } label: {
                    Label(viewModel.group.name.isEmpty ? "Set group name" : "Edit group name",
                          systemImage: "pencil")
                }

                Button {
                    showGroupImageEditor = true
                } label: {
                    Label(viewModel.group.avatarUrl == nil ? "Set group image" : "Edit group image",
                          systemImage: "photo")
                }
            }
        }
    }

    private var infoSection: some View {
        Section {
            LabeledContent("Group ID") {
                Text(IdentityFormatter.short(viewModel.group.groupIdHex))
                    .font(.system(.caption, design: .monospaced))
            }
            LabeledContent("Members", value: "\(memberCount)")
            DisclosureGroup(isExpanded: $showRelays) {
                // Stable per-row identity by position. Sanitized display strings can
                // collide (distinct raw relays sanitize to the same line), so id: \.self
                // would produce duplicate SwiftUI identities on hostile relay input.
                ForEach(Array(GroupRelaysPresentation.rows(for: viewModel.group.relays).enumerated()), id: \.offset) { _, relay in
                    Text(relay)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(relay == GroupRelaysPresentation.emptyMessage ? .secondary : .primary)
                        .textSelection(.enabled)
                }
            } label: {
                HStack {
                    Text("Relays")
                    Spacer()
                    Text(GroupRelaysPresentation.countLabel(for: viewModel.group.relays))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var membersSection: some View {
        Section {
            if viewModel.groupMemberDetails.isEmpty {
                ForEach(viewModel.members, id: \.memberIdHex) { member in
                    GroupMemberRow(member: member, isAdmin: viewModel.isAdmin(member))
                }
            } else {
                ForEach(viewModel.groupMemberDetails, id: \.memberIdHex) { member in
                    HStack(spacing: 8) {
                        GroupMemberDetailsRow(member: member)
                        memberActionsMenu(for: member)
                    }
                    .swipeActions(edge: .trailing) {
                        swipeActions(for: member)
                    }
                }
            }

            if GroupManagementPresentation.canInvite(
                state: viewModel.managementState,
                fallbackIsAdmin: isAdmin
            ) {
                Button {
                    showAddMembers = true
                } label: {
                    Label("Add Members", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(membershipActionInFlight)
            }
        } footer: {
            if !GroupManagementPresentation.canInvite(
                state: viewModel.managementState,
                fallbackIsAdmin: isAdmin
            ) {
                Text("Only admins can add or manage members.")
            }
        }
    }

    private var groupActionsSection: some View {
        Section {
            groupActionRow(
                title: viewModel.group.archived ? L10n.string("Unarchive Group") : L10n.string("Archive Group"),
                systemImage: viewModel.group.archived ? "tray.and.arrow.up" : "archivebox",
                isDisabled: membershipActionInFlight,
                help: .archive
            ) {
                Task { await setArchived(!viewModel.group.archived) }
            }

            if shouldShowSelfDemoteAction {
                groupActionRow(
                    title: L10n.string("Step Down as Admin"),
                    systemImage: "star.slash",
                    role: .destructive,
                    isDisabled: !canSelfDemoteAction || membershipActionInFlight,
                    help: .stepDown
                ) {
                    pendingConfirmation = .selfDemote
                }
            }

            groupActionRow(
                title: L10n.string("Leave Group"),
                systemImage: "rectangle.portrait.and.arrow.right",
                role: .destructive,
                isDisabled: !GroupManagementPresentation.canLeave(
                    state: viewModel.managementState,
                    fallbackIsLastAdmin: viewModel.isLastAdmin
                )
                    || membershipActionInFlight,
                help: .leave(message: GroupManagementPresentation.leaveHelpMessage(
                    state: viewModel.managementState,
                    fallbackIsLastAdmin: viewModel.isLastAdmin
                ))
            ) {
                pendingConfirmation = .leave
            }
        }
    }

    private var transcriptExportSection: some View {
        Section {
            Button {
                Task { await exportConversationTranscript() }
            } label: {
                HStack {
                    Label("Export Conversation Transcript", systemImage: "doc.text")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isExportingTranscript {
                        ProgressView()
                    }
                }
            }
            .disabled(isExportingTranscript || appState.activeAccountRef == nil)
        } footer: {
            Text("Exports the raw inner Nostr event history for this group as JSON (kinds 9, 1200–1210, and related metadata), ordered by time. Use Share to copy or save the file.")
        }
    }

    private var shouldShowSelfDemoteAction: Bool {
        isAdmin || viewModel.managementState?.requiresSelfDemoteBeforeLeave == true
    }

    private var canSelfDemoteAction: Bool {
        if GroupManagementPresentation.canSelfDemote(state: viewModel.managementState) { return true }
        return viewModel.managementState == nil && isAdmin && !viewModel.isLastAdmin
    }

    private func groupActionRow(
        title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        isDisabled: Bool,
        help: GroupActionHelp,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Button(role: role, action: action) {
                groupActionLabel(title, systemImage: systemImage)
            }
            .disabled(isDisabled)

            Button {
                actionHelp = help
            } label: {
                Image(systemName: "info.circle")
                    .imageScale(.large)
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(L10n.formatted("%@ info", title))
        }
    }

    private func groupActionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private var developerSection: some View {
        Section {
            copyableDeveloperValueRow(
                title: "MLS group ID",
                value: mlsState?.groupIdHex ?? viewModel.group.groupIdHex
            )
            copyableDeveloperValueRow(title: "Nostr group ID", value: viewModel.group.nostrGroupIdHex)
            if let mlsState {
                LabeledContent("Epoch", value: "\(mlsState.epoch)")
                LabeledContent("Members (MLS)", value: "\(mlsState.memberCount)")
                LabeledContent("Required components") {
                    Text(mlsState.requiredAppComponents.map(String.init).joined(separator: ", "))
                        .font(.caption.monospaced())
                }
            } else {
                Text("Loading MLS state…")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Admins", value: "\(viewModel.group.admins.count)")
        } header: {
            Text("MLS group (developer)")
        }
    }

    private var pushNotificationsDeveloperSection: some View {
        Section("Push notifications (developer)") {
            if let pushDebugInfo {
                LabeledContent("Tokens") {
                    Text(GroupPushDebugPresentation.tokenSummary(for: pushDebugInfo))
                        .monospacedDigit()
                }
                LabeledContent("Relay hints") {
                    Text(GroupPushDebugPresentation.missingRelayHintSummary(for: pushDebugInfo))
                        .monospacedDigit()
                }
                LabeledContent("Local registration") {
                    Text(GroupPushDebugPresentation.localRegistrationSummary(for: pushDebugInfo.localRegistration))
                        .foregroundStyle(.secondary)
                }
                if let leafIndex = pushDebugInfo.localRegistration.localLeafIndex {
                    LabeledContent("Local leaf", value: "\(leafIndex)")
                }
                if let updatedAtMs = pushDebugInfo.lastTokenListUpdatedAtMs {
                    LabeledContent("Last token list update") {
                        Text(Date(timeIntervalSince1970: TimeInterval(updatedAtMs) / 1000), style: .relative)
                    }
                }
                if !pushDebugInfo.tokens.isEmpty {
                    DisclosureGroup("Token fingerprints") {
                        ForEach(pushDebugInfo.tokens, id: \.self) { token in
                            tokenDebugRow(token)
                        }
                    }
                }
            } else if let pushDebugError {
                Label(pushDebugError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Text("Loading push notification state…")
                    .foregroundStyle(.secondary)
            }
        }
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

    private func tokenDebugRow(_ token: GroupPushTokenDebugEntryFfi) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(GroupPushDebugPresentation.platformLabel(token.platform))
                    .font(.caption.weight(.semibold))
                Text("leaf \(token.leafIndex)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if token.isLocalMember {
                    Text("local")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                        .foregroundStyle(.tint)
                }
                if !token.activeLeaf {
                    Text("stale")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.16), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            Text(token.tokenFingerprint)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(IdentityFormatter.short(token.memberIdHex, head: 12, tail: 12))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    @ViewBuilder
    private func memberActionsMenu(for member: GroupMemberDetailsFfi) -> some View {
        // Copy npub is available to every member, so the menu always renders.
        // Membership-management actions (admin/remove) stay gated on the
        // caller's permissions and only appear when applicable.
        Menu {
            Button {
                copyNpub(for: member)
            } label: {
                Label("Copy npub", systemImage: "doc.on.doc")
            }

            let actions = memberActions(for: member)
            if !actions.isEmpty {
                Divider()
                memberActionButtons(for: member, actions: actions)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .imageScale(.large)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Member actions")
    }

    @ViewBuilder
    private func memberActionButtons(
        for member: GroupMemberDetailsFfi,
        actions: [GroupMemberManagementAction]
    ) -> some View {
        if actions.contains(.promote) {
            Button {
                Task { await setAdmin(member: member, admin: true) }
            } label: {
                Label("Make Admin", systemImage: "star")
            }
            .disabled(membershipActionInFlight)
        }
        if actions.contains(.demote) {
            Button {
                Task { await setAdmin(member: member, admin: false) }
            } label: {
                Label("Remove Admin", systemImage: "star.slash")
            }
            .disabled(membershipActionInFlight)
        }
        if actions.contains(.selfDemote) {
            Button(role: .destructive) {
                pendingConfirmation = .selfDemote
            } label: {
                Label("Step Down as Admin", systemImage: "star.slash")
            }
            .disabled(membershipActionInFlight)
        }
        if actions.contains(.remove) {
            Button(role: .destructive) {
                pendingConfirmation = .remove(member)
            } label: {
                Label("Remove from Group", systemImage: "person.crop.circle.badge.minus")
            }
            .disabled(membershipActionInFlight)
        }
    }

    private func copyNpub(for member: GroupMemberDetailsFfi) {
        UIPasteboard.general.string = member.npub
        Haptics.selection()
        appState.present(.success(L10n.string("Copied to clipboard"), message: L10n.string("npub")))
    }

    @ViewBuilder
    private func swipeActions(for member: GroupMemberDetailsFfi) -> some View {
        let actions = memberActions(for: member)
        if actions.contains(.remove) {
            Button(role: .destructive) {
                pendingConfirmation = .remove(member)
            } label: {
                Label("Remove", systemImage: "person.crop.circle.badge.minus")
            }
        }
        if actions.contains(.demote) {
            Button {
                Task { await setAdmin(member: member, admin: false) }
            } label: {
                Label("Remove Admin", systemImage: "star.slash")
            }
            .tint(.orange)
        }
        if actions.contains(.promote) {
            Button {
                Task { await setAdmin(member: member, admin: true) }
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

    private func invite(refs: [String]) async throws {
        guard let accountRef = appState.activeAccountRef else { throw GroupDetailsActionError.noActiveAccount }
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        do {
            appState.present(.warning(L10n.string("Inviting members…"), message: L10n.string("Publishing group update.")))
            let result = try await appState.marmot.inviteMembersDetailed(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex,
                memberRefs: refs
            )
            viewModel.applyGroupMutation(result)
            await refreshVisibleDebugState()
            Haptics.success()
            appState.present(.success(
                L10n.plural("Invited %lld members", Int64(refs.count)),
                message: publishMessage(for: result.summary)
            ))
        } catch {
            await refreshAfterFailedMutation()
            handleActionError(error, title: L10n.string("Invite failed"))
            throw error
        }
    }

    private func remove(member: GroupMemberDetailsFfi) async {
        pendingConfirmation = nil
        guard let accountRef = appState.activeAccountRef else { return }
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        do {
            appState.present(.warning(L10n.string("Removing member…"), message: L10n.string("Publishing group update.")))
            let result = try await appState.marmot.removeMembersDetailed(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex,
                memberRefs: [member.memberIdHex]
            )
            viewModel.applyGroupMutation(result)
            await refreshVisibleDebugState()
            Haptics.success()
            appState.present(.warning(L10n.string("Member removed"), message: publishMessage(for: result.summary)))
        } catch {
            await refreshAfterFailedMutation()
            handleActionError(error, title: L10n.string("Couldn't remove member"))
        }
    }

    private func setAdmin(member: GroupMemberDetailsFfi, admin: Bool) async {
        guard let accountRef = appState.activeAccountRef else { return }
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        viewModel.applyOptimisticAdminStatus(memberIdHex: member.memberIdHex, isAdmin: admin)
        appState.present(.warning(
            admin ? L10n.string("Making admin…") : L10n.string("Removing admin…"),
            message: L10n.string("Publishing group update.")
        ))
        do {
            let result: GroupMutationResultFfi
            if admin {
                result = try await appState.marmot.promoteAdminDetailed(
                    accountRef: accountRef,
                    groupIdHex: viewModel.group.groupIdHex,
                    memberRef: member.memberIdHex
                )
            } else {
                result = try await appState.marmot.demoteAdminDetailed(
                    accountRef: accountRef,
                    groupIdHex: viewModel.group.groupIdHex,
                    memberRef: member.memberIdHex
                )
            }
            viewModel.applyGroupMutation(result)
            await refreshVisibleDebugState()
            Haptics.success()
            appState.present(
                admin
                    ? .success(L10n.string("Made admin"), message: publishMessage(for: result.summary))
                    : .warning(L10n.string("Admin removed"), message: publishMessage(for: result.summary))
            )
        } catch {
            await refreshAfterFailedMutation()
            handleActionError(error, title: L10n.string("Couldn't change admin"))
        }
    }

    private func selfDemote() async {
        guard let accountRef = appState.activeAccountRef else { return }
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        if let myAccountId = viewModel.managementState?.myAccountIdHex {
            viewModel.applyOptimisticAdminStatus(memberIdHex: myAccountId, isAdmin: false)
        }
        appState.present(.warning(L10n.string("Stepping down…"), message: L10n.string("Publishing group update.")))
        do {
            let result = try await appState.marmot.selfDemoteAdminDetailed(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex
            )
            viewModel.applyGroupMutation(result)
            await refreshVisibleDebugState()
            Haptics.success()
            appState.present(.warning(L10n.string("You stepped down as admin"), message: publishMessage(for: result.summary)))
        } catch {
            await refreshAfterFailedMutation()
            handleActionError(error, title: L10n.string("Couldn't step down"))
        }
    }

    /// A group rename must publish a non-empty sanitized name; an empty value
    /// would silently blank the shared group name (#80), and raw text would
    /// propagate spoofing characters to Marmot/relays (#195).
    static func validatedGroupName(_ draft: String) -> String? {
        ProfileSanitizer.groupName(draft)
    }

    private func rename() async {
        guard let accountRef = appState.activeAccountRef,
              let name = Self.validatedGroupName(renameDraft) else { return }
        do {
            appState.present(.warning(L10n.string("Updating group name…"), message: L10n.string("Publishing group update.")))
            let summary = try await appState.marmot.updateGroupProfile(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex,
                name: name,
                description: nil
            )
            await refreshGroupManagementAndNotify()
            await refreshVisibleDebugState()
            Haptics.success()
            appState.present(.success(L10n.string("Group name updated"), message: publishMessage(for: summary)))
        } catch {
            await refreshAfterFailedMutation()
            Haptics.error()
            actionError = error.localizedDescription
            appState.present(.error(L10n.string("Couldn't rename group"), message: error.localizedDescription))
        }
    }

    private func updateGroupImage(url: String?) async throws {
        guard let accountRef = appState.activeAccountRef else { throw GroupDetailsActionError.noActiveAccount }
        let normalizedURL: String?
        if let url {
            guard let sanitized = GroupImageURLSheet.validatedImageURL(url) else {
                throw GroupDetailsActionError.invalidImageURL
            }
            normalizedURL = sanitized.absoluteString
        } else {
            normalizedURL = nil
        }

        do {
            appState.present(.warning(L10n.string("Updating group image…"), message: L10n.string("Publishing group update.")))
            let summary = try await appState.marmot.updateGroupAvatarUrl(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex,
                url: normalizedURL,
                dim: nil,
                thumbhash: nil
            )
            await refreshGroupManagementAndNotify()
            await refreshVisibleDebugState()
            Haptics.success()
            appState.present(.success(
                normalizedURL == nil ? L10n.string("Group image removed") : L10n.string("Group image updated"),
                message: publishMessage(for: summary)
            ))
        } catch {
            await refreshAfterFailedMutation()
            Haptics.error()
            actionError = error.localizedDescription
            appState.present(.error(L10n.string("Couldn't update group image"), message: error.localizedDescription))
            throw error
        }
    }

    private func setArchived(_ archived: Bool) async {
        guard let accountRef = appState.activeAccountRef else { return }
        do {
            let record = try await appState.marmot.setGroupArchived(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex,
                archived: archived
            )
            viewModel.applyGroupRecord(record)
            onGroupChanged(record)
            await refreshVisibleDebugState()
            Haptics.success()
            appState.present(archived ? .warning(L10n.string("Group archived")) : .success(L10n.string("Group unarchived")))
        } catch {
            Haptics.error()
            actionError = error.localizedDescription
            appState.present(.error(L10n.string("Couldn't update archive"), message: error.localizedDescription))
        }
    }

    private func leave() async {
        guard let accountRef = appState.activeAccountRef else { return }
        guard GroupManagementPresentation.canLeave(
            state: viewModel.managementState,
            fallbackIsLastAdmin: viewModel.isLastAdmin
        ) else {
            actionError = GroupManagementPresentation.leaveFooter(
                state: viewModel.managementState,
                fallbackIsLastAdmin: viewModel.isLastAdmin
            )
            return
        }
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        do {
            if GroupManagementPresentation.shouldSelfDemoteBeforeLeave(state: viewModel.managementState) {
                if let myAccountId = viewModel.managementState?.myAccountIdHex {
                    viewModel.applyOptimisticAdminStatus(memberIdHex: myAccountId, isAdmin: false)
                }
                appState.present(.warning(L10n.string("Stepping down before leaving…"), message: L10n.string("Publishing group update.")))
                let result = try await appState.marmot.selfDemoteAdminDetailed(
                    accountRef: accountRef,
                    groupIdHex: viewModel.group.groupIdHex
                )
                viewModel.applyGroupMutation(result)
                await refreshVisibleDebugState()
            }
            appState.present(.warning(L10n.string("Leaving group…"), message: L10n.string("Publishing group update.")))
            _ = try await appState.marmot.leaveGroup(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex
            )
            Haptics.warning()
            appState.present(.warning(L10n.string("You left the group")))
            dismiss()
        } catch {
            await refreshAfterFailedMutation()
            handleActionError(error, title: L10n.string("Couldn't leave group"))
        }
    }

    private func handleActionError(_ error: Error, title: String) {
        let message = actionMessage(for: error)
        Haptics.error()
        actionError = message
        appState.present(.error(title, message: message))
    }

    private func actionMessage(for error: Error) -> String {
        guard let marmotError = error as? MarmotKitError else {
            return error.localizedDescription
        }
        switch marmotError {
        case .NotGroupAdmin:
            return L10n.string("Only admins can manage group members.")
        case .AdminCannotSelfRemove:
            return L10n.string("Step down as admin before leaving the group.")
        case .WouldRemoveLastAdmin:
            return L10n.string("Make another member an admin before removing the last admin.")
        case .MemberNotInGroup:
            return L10n.string("That member is no longer in this group.")
        case .AlreadyAdmin:
            return L10n.string("That member is already an admin.")
        case .NotAdmin:
            return L10n.string("That member is not an admin.")
        case .MissingKeyPackage(let account):
            return L10n.formatted(
                "%@ hasn't published a compatible key package yet.",
                IdentityFormatter.short(account)
            )
        default:
            return marmotError.localizedDescription
        }
    }

    private func publishMessage(for summary: SendSummaryFfi) -> String {
        guard summary.published > 0 else { return L10n.string("Saved locally.") }
        return L10n.plural("Published %lld updates.", Int64(clamping: summary.published))
    }

    private func refreshAfterFailedMutation() async {
        _ = await viewModel.refreshGroupManagement()
        await refreshVisibleDebugState()
    }

    private func refreshGroupManagementAndNotify() async {
        if await viewModel.refreshGroupManagement() {
            onGroupChanged(viewModel.group)
        }
    }

    private func exportConversationTranscript() async {
        guard !isExportingTranscript,
              let accountRef = appState.activeAccountRef
        else { return }

        isExportingTranscript = true
        defer { isExportingTranscript = false }

        cleanupTranscriptExportFile()

        do {
            let client = try appState.currentMarmotClient()
            let url = try await client.exportConversationTranscript(
                accountRef: accountRef,
                group: viewModel.group
            )
            transcriptExportURL = url
            showTranscriptShareSheet = true
        } catch is CancellationError {
            // The export task can be cancelled while the detached worker is paging history.
        } catch {
            transcriptExportError = error.localizedDescription
        }
    }

    private func cleanupTranscriptExportFile() {
        if let transcriptExportURL {
            try? FileManager.default.removeItem(at: transcriptExportURL)
        }
        transcriptExportURL = nil
    }

    private func refreshVisibleDebugState() async {
        guard appState.developerMode else {
            mlsState = nil
            pushDebugInfo = nil
            pushDebugError = nil
            return
        }
        guard let accountRef = appState.activeAccountRef else { return }
        async let mlsResult = appState.marmot.groupMlsState(
            accountRef: accountRef,
            groupIdHex: viewModel.group.groupIdHex
        )
        async let pushResult = appState.marmot.groupPushDebugInfo(
            accountRef: accountRef,
            groupIdHex: viewModel.group.groupIdHex
        )
        mlsState = try? await mlsResult
        do {
            pushDebugInfo = try await pushResult
            pushDebugError = nil
        } catch {
            pushDebugInfo = nil
            pushDebugError = error.localizedDescription
        }
    }
}

private enum GroupDetailsActionError: LocalizedError {
    case noActiveAccount
    case invalidImageURL

    var errorDescription: String? {
        switch self {
        case .noActiveAccount:
            L10n.string("No active account is selected.")
        case .invalidImageURL:
            L10n.string("Use a public HTTPS image URL.")
        }
    }
}

private enum GroupActionHelp {
    case stepDown
    case archive
    case leave(message: String)

    var title: String {
        switch self {
        case .stepDown:
            return L10n.string("Step Down as Admin")
        case .archive:
            return L10n.string("Archive Group")
        case .leave:
            return L10n.string("Leave Group")
        }
    }

    var message: String {
        switch self {
        case .stepDown:
            return L10n.string("You'll stay in the group, but another admin will need to restore your admin status.")
        case .archive:
            return L10n.string("Archiving hides the group from your main chats list. It doesn't change your membership or notify anyone.")
        case .leave(let message):
            return message
        }
    }
}

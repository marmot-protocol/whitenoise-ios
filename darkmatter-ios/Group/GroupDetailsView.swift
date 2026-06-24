import SwiftUI
import UIKit
import MarmotKit

enum GroupDetailsConfirmation: Identifiable {
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

    @State private var model = GroupDetailsViewModel()

    private var isAdmin: Bool { viewModel.isSelfAdmin }
    private var memberCount: Int {
        viewModel.groupMemberDetails.isEmpty ? viewModel.members.count : viewModel.groupMemberDetails.count
    }

    var body: some View {
        @Bindable var model = model
        // @ObservationIgnored, so this never triggers a re-render; it guarantees
        // the model's conversation/onGroupChanged are set before any method runs.
        model.conversation = viewModel
        model.onGroupChanged = onGroupChanged
        return Form {
            headerSection
            membersSection
            infoSection
            groupActionsSection

            if appState.developerMode {
                transcriptExportSection
                developerSection
                pushNotificationsDeveloperSection
            }

            if let actionError = model.actionError {
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
        .sheet(isPresented: $model.showAddMembers) {
            AddMembersSheet(
                normalize: { try await appState.currentMarmotClient().normalizeMemberRef(memberRef: $0) },
                onSubmit: { refs in try await model.invite(refs: refs, using: appState) }
            )
            .appAppearance()
        }
        .sheet(isPresented: $model.showGroupImageEditor) {
            GroupImageURLSheet(initialURL: viewModel.group.avatarUrl) { url in
                try await model.updateGroupImage(url: url, using: appState)
            }
            .appAppearance()
        }
        .alert("Group name", isPresented: $model.showRename) {
            TextField("Group name", text: $model.renameDraft)
            Button("Save") { Task { await model.rename(using: appState) } }
                .disabled(Self.validatedGroupName(model.renameDraft) == nil)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Everyone in the group will see the new name.")
        }
        .fullScreenCover(item: $model.pendingConfirmation) { confirmation in
            fullScreenConfirmation(for: confirmation)
                .appAppearance()
        }
        .alert(model.actionHelp?.title ?? "", isPresented: actionHelpBinding) {
            Button("OK", role: .cancel) { model.actionHelp = nil }
        } message: {
            Text(model.actionHelp?.message ?? "")
        }
        .alert(
            "Export failed",
            isPresented: Binding(
                get: { model.transcriptExportError != nil },
                set: { if !$0 { model.transcriptExportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.transcriptExportError = nil }
        } message: {
            Text(model.transcriptExportError ?? "")
        }
        .sheet(isPresented: $model.showTranscriptShareSheet, onDismiss: model.cleanupTranscriptExportFile) {
            if let transcriptExportURL = model.transcriptExportURL {
                ActivityShareSheet(items: [transcriptExportURL], onComplete: model.cleanupTranscriptExportFile)
            }
        }
        .task(id: appState.developerMode) {
            await model.refreshGroupManagementAndNotify()
            await model.refreshVisibleDebugState(using: appState)
        }
        .task(id: viewModel.groupMlsRefreshGeneration) {
            await model.refreshVisibleDebugState(using: appState)
        }
    }

    // MARK: - Sections

    private var actionHelpBinding: Binding<Bool> {
        Binding(
            get: { model.actionHelp != nil },
            set: { if !$0 { model.actionHelp = nil } }
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
                    model.pendingConfirmation = nil
                    Task { await model.leave(using: appState, dismiss: dismiss) }
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
                    model.renameDraft = ProfileSanitizer.groupName(viewModel.group.name) ?? ""
                    model.showRename = true
                } label: {
                    Label(viewModel.group.name.isEmpty ? "Set group name" : "Edit group name",
                          systemImage: "pencil")
                }

                Button {
                    model.showGroupImageEditor = true
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
            LabeledContent(
                "Disappearing messages",
                value: GroupSystemEventPresentation.retentionSettingLabel(
                    seconds: viewModel.group.disappearingMessageSecs
                )
            )
            DisclosureGroup(isExpanded: $model.showRelays) {
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
                    model.showAddMembers = true
                } label: {
                    Label("Add Members", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(model.membershipActionInFlight)
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
                isDisabled: model.membershipActionInFlight,
                help: .archive
            ) {
                Task { await model.setArchived(!viewModel.group.archived, using: appState) }
            }

            if shouldShowSelfDemoteAction {
                groupActionRow(
                    title: L10n.string("Step Down as Admin"),
                    systemImage: "star.slash",
                    role: .destructive,
                    isDisabled: !canSelfDemoteAction || model.membershipActionInFlight,
                    help: .stepDown
                ) {
                    model.pendingConfirmation = .selfDemote
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
                    || model.membershipActionInFlight,
                help: .leave(message: GroupManagementPresentation.leaveHelpMessage(
                    state: viewModel.managementState,
                    fallbackIsLastAdmin: viewModel.isLastAdmin
                ))
            ) {
                model.pendingConfirmation = .leave
            }
        }
    }

    private var transcriptExportSection: some View {
        Section {
            Button {
                Task { await model.exportConversationTranscript(using: appState) }
            } label: {
                HStack {
                    Label("Export Conversation Transcript", systemImage: "doc.text")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if model.isExportingTranscript {
                        ProgressView()
                    }
                }
            }
            .disabled(model.isExportingTranscript || appState.activeAccountRef == nil)
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
                model.actionHelp = help
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
                value: model.mlsState?.groupIdHex ?? viewModel.group.groupIdHex
            )
            copyableDeveloperValueRow(title: "Nostr group ID", value: viewModel.group.nostrGroupIdHex)
            if let mlsState = model.mlsState {
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
            if let pushDebugInfo = model.pushDebugInfo {
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
            } else if let pushDebugError = model.pushDebugError {
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
                Task { await model.setAdmin(member: member, admin: true, using: appState) }
            } label: {
                Label("Make Admin", systemImage: "star")
            }
            .disabled(model.membershipActionInFlight)
        }
        if actions.contains(.demote) {
            Button {
                Task { await model.setAdmin(member: member, admin: false, using: appState) }
            } label: {
                Label("Remove Admin", systemImage: "star.slash")
            }
            .disabled(model.membershipActionInFlight)
        }
        if actions.contains(.selfDemote) {
            Button(role: .destructive) {
                model.pendingConfirmation = .selfDemote
            } label: {
                Label("Step Down as Admin", systemImage: "star.slash")
            }
            .disabled(model.membershipActionInFlight)
        }
        if actions.contains(.remove) {
            Button(role: .destructive) {
                model.pendingConfirmation = .remove(member)
            } label: {
                Label("Remove from Group", systemImage: "person.crop.circle.badge.minus")
            }
            .disabled(model.membershipActionInFlight)
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

    /// A group rename must publish a non-empty sanitized name; an empty value
    /// would silently blank the shared group name (#80), and raw text would
    /// propagate spoofing characters to Marmot/relays (#195).
    static func validatedGroupName(_ draft: String) -> String? {
        ProfileSanitizer.groupName(draft)
    }

}

enum GroupDetailsActionError: LocalizedError {
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

enum GroupActionHelp {
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

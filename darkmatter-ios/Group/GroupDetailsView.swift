import SwiftUI
import UIKit
import MarmotKit

/// Inspector for a single group. Name, members + admin management,
/// invite/remove, archive, leave, and (in developer mode) MLS internals.
struct GroupDetailsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: ConversationViewModel

    @State private var showAddMembers = false
    @State private var showLeaveConfirm = false
    @State private var showRename = false
    @State private var renameDraft = ""
    @State private var actionError: String?
    @State private var mlsState: AppGroupMlsStateFfi?
    @State private var pushDebugInfo: GroupPushDebugInfoFfi?
    @State private var pushDebugError: String?
    @State private var forensicsDump: GroupForensicsDump?
    @State private var forensicsDumpError: String?
    @State private var forensicsDumpInFlight = false
    @State private var showPrivateDumpConfirm = false
    @State private var pendingRemoval: GroupMemberDetailsFfi?
    @State private var showSelfDemoteConfirm = false
    @State private var membershipActionInFlight = false
    @State private var showRelays = false
    @State private var actionHelp: GroupActionHelp?

    private var isAdmin: Bool { viewModel.isSelfAdmin }
    private var memberCount: Int {
        viewModel.groupMemberDetails.isEmpty ? viewModel.members.count : viewModel.groupMemberDetails.count
    }
    private var mlsRefreshKey: String {
        [
            viewModel.group.groupIdHex,
            viewModel.group.admins.joined(separator: ","),
            viewModel.members.map(\.memberIdHex).joined(separator: ","),
            viewModel.groupMemberDetails.map { "\($0.memberIdHex):\($0.isAdmin)" }.joined(separator: ",")
        ].joined(separator: "|")
    }

    var body: some View {
        Form {
            headerSection
            membersSection
            infoSection
            groupActionsSection

            if appState.developerMode {
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
                normalize: { try appState.marmot.normalizeMemberRef(memberRef: $0) },
                onSubmit: { refs in try await invite(refs: refs) }
            )
            .appAppearance()
        }
        .alert("Group name", isPresented: $showRename) {
            TextField("Group name", text: $renameDraft)
            Button("Save") { Task { await rename() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Everyone in the group will see the new name.")
        }
        .confirmationDialog(
            "Leave this group?",
            isPresented: $showLeaveConfirm,
            titleVisibility: .visible
        ) {
            Button("Leave", role: .destructive) {
                Task { await leave() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(GroupManagementPresentation.leaveConfirmationMessage(state: viewModel.managementState))
        }
        .confirmationDialog(
            "Remove this member?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove from Group", role: .destructive) {
                guard let pendingRemoval else { return }
                Task { await remove(member: pendingRemoval) }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("They'll stop receiving new messages in this group.")
        }
        .confirmationDialog(
            "Step down as admin?",
            isPresented: $showSelfDemoteConfirm,
            titleVisibility: .visible
        ) {
            Button("Step Down", role: .destructive) {
                Task { await selfDemote() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You'll stay in the group, but another admin will need to restore your admin status.")
        }
        .alert(actionHelp?.title ?? "", isPresented: actionHelpBinding) {
            Button("OK", role: .cancel) { actionHelp = nil }
        } message: {
            Text(actionHelp?.message ?? "")
        }
        .confirmationDialog(
            String("Generate private debug dump?"),
            isPresented: $showPrivateDumpConfirm,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await generateForensicsDump(mode: .sensitive) }
            } label: {
                Text(verbatim: "Generate Private Debug Dump")
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(verbatim: "Private dumps include unredacted local group state, plaintext messages, identifiers, relay URLs, and payload bytes. Share only with people you trust to debug this group.")
        }
        .task(id: appState.developerMode) {
            await viewModel.refreshGroupManagement()
            await refreshVisibleDebugState()
        }
        .task(id: mlsRefreshKey) {
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
                    if let description = ProfileSanitizer.multilineText(viewModel.group.description, maxLength: 280) {
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
                    renameDraft = viewModel.group.name
                    showRename = true
                } label: {
                    Label(viewModel.group.name.isEmpty ? "Set group name" : "Edit group name",
                          systemImage: "pencil")
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
                ForEach(GroupRelaysPresentation.rows(for: viewModel.group.relays), id: \.self) { relay in
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
                    showSelfDemoteConfirm = true
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
                showLeaveConfirm = true
            }
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
            .accessibilityLabel(L10n.string("\(title) info"))
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

            groupForensicsDeveloperControls
        } header: {
            Text("MLS group (developer)")
        } footer: {
            Text(verbatim: "Public dumps are redacted. Private dumps include unredacted local group state.")
        }
    }

    @ViewBuilder
    private var groupForensicsDeveloperControls: some View {
        Button {
            Task { await generateForensicsDump(mode: .`public`) }
        } label: {
            Label {
                Text(verbatim: "Generate Public Debug Dump")
            } icon: {
                Image(systemName: "doc.badge.gearshape")
            }
        }
        .disabled(forensicsDumpInFlight)

        Button(role: .destructive) {
            showPrivateDumpConfirm = true
        } label: {
            Label {
                Text(verbatim: "Generate Private Debug Dump")
            } icon: {
                Image(systemName: "lock.doc")
            }
        }
        .disabled(forensicsDumpInFlight)

        if forensicsDumpInFlight {
            ProgressView {
                Text(verbatim: "Generating dump…")
            }
        }

        if let forensicsDump {
            LabeledContent {
                Text(forensicsDump.generatedAt, style: .time)
            } label: {
                Text(verbatim: "Generated")
            }
            LabeledContent {
                Text(verbatim: GroupForensicsPresentation.modeLabel(forensicsDump.mode))
            } label: {
                Text(verbatim: "Type")
            }
            LabeledContent {
                Text(verbatim: forensicsDump.sizeLabel)
            } label: {
                Text(verbatim: "Size")
            }
            ShareLink(item: forensicsDump.url) {
                Label {
                    Text(verbatim: "Share JSON File")
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            Button {
                UIPasteboard.general.string = forensicsDump.json
                Haptics.selection()
                appState.present(.success(L10n.string("Copied to clipboard"), message: "Forensics JSON"))
            } label: {
                Label {
                    Text(verbatim: "Copy JSON")
                } icon: {
                    Image(systemName: "doc.on.doc")
                }
            }
        }

        if let forensicsDumpError {
            Label(forensicsDumpError, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
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
        .accessibilityHint("Copies \(title)")
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

    private func clearGeneratedForensicsDump() {
        forensicsDump = nil
        forensicsDumpError = nil
    }

    @ViewBuilder
    private func memberActionsMenu(for member: GroupMemberDetailsFfi) -> some View {
        let actions = memberActions(for: member)
        if !actions.isEmpty {
            Menu {
                memberActionButtons(for: member, actions: actions)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(membershipActionInFlight)
            .accessibilityLabel("Member actions")
        }
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
        }
        if actions.contains(.demote) {
            Button {
                Task { await setAdmin(member: member, admin: false) }
            } label: {
                Label("Remove Admin", systemImage: "star.slash")
            }
        }
        if actions.contains(.selfDemote) {
            Button(role: .destructive) {
                showSelfDemoteConfirm = true
            } label: {
                Label("Step Down as Admin", systemImage: "star.slash")
            }
        }
        if actions.contains(.remove) {
            Button(role: .destructive) {
                pendingRemoval = member
            } label: {
                Label("Remove from Group", systemImage: "person.crop.circle.badge.minus")
            }
        }
    }

    @ViewBuilder
    private func swipeActions(for member: GroupMemberDetailsFfi) -> some View {
        let actions = memberActions(for: member)
        if actions.contains(.remove) {
            Button(role: .destructive) {
                pendingRemoval = member
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
                refs.count == 1 ? L10n.string("Invited 1 member") : L10n.string("Invited \(refs.count) members"),
                message: publishMessage(for: result.summary)
            ))
        } catch {
            await refreshAfterFailedMutation()
            handleActionError(error, title: L10n.string("Invite failed"))
            throw error
        }
    }

    private func remove(member: GroupMemberDetailsFfi) async {
        pendingRemoval = nil
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

    private func rename() async {
        guard let accountRef = appState.activeAccountRef else { return }
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            appState.present(.warning(L10n.string("Updating group name…"), message: L10n.string("Publishing group update.")))
            let summary = try await appState.marmot.updateGroupProfile(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex,
                name: name,
                description: nil
            )
            await viewModel.refreshGroupManagement()
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

    private func setArchived(_ archived: Bool) async {
        guard let accountRef = appState.activeAccountRef else { return }
        do {
            let record = try appState.marmot.setGroupArchived(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex,
                archived: archived
            )
            viewModel.applyGroupRecord(record)
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

    private func generateForensicsDump(mode: ForensicsDumpModeFfi) async {
        guard let accountRef = appState.activeAccountRef else { return }

        forensicsDumpInFlight = true
        clearGeneratedForensicsDump()
        defer { forensicsDumpInFlight = false }
        do {
            let json = try await appState.marmot.groupForensicsJson(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex,
                mode: mode,
                publicRedactionSaltHex: nil
            )
            let generatedAt = Date()
            let url = try writeForensicsDump(json: json, mode: mode, generatedAt: generatedAt)
            forensicsDump = GroupForensicsDump(
                json: json,
                url: url,
                mode: mode,
                generatedAt: generatedAt
            )
            forensicsDumpError = nil
            Haptics.success()
            appState.present(.success(
                "\(GroupForensicsPresentation.modeLabel(mode)) debug dump ready",
                message: "Share or copy it from group details."
            ))
        } catch {
            forensicsDump = nil
            forensicsDumpError = error.localizedDescription
            Haptics.error()
            appState.present(.error("Couldn't generate dump", message: error.localizedDescription))
        }
    }

    private func writeForensicsDump(
        json: String,
        mode: ForensicsDumpModeFfi,
        generatedAt: Date
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MarmotForensics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = GroupForensicsPresentation.fileName(
            groupTitle: viewModel.displayTitle,
            groupIdHex: viewModel.group.groupIdHex,
            mode: mode,
            generatedAt: generatedAt
        )
        let url = directory.appendingPathComponent(filename)
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
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
            return L10n.string("\(IdentityFormatter.short(account)) hasn't published a compatible key package yet.")
        default:
            return marmotError.localizedDescription
        }
    }

    private func publishMessage(for summary: SendSummaryFfi) -> String {
        guard summary.published > 0 else { return L10n.string("Saved locally.") }
        return summary.published == 1
            ? L10n.string("Published 1 update.")
            : L10n.string("Published \(summary.published) updates.")
    }

    private func refreshAfterFailedMutation() async {
        _ = await viewModel.refreshGroupManagement()
        await refreshVisibleDebugState()
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

private struct GroupForensicsDump: Identifiable {
    let id = UUID()
    let json: String
    let url: URL
    let mode: ForensicsDumpModeFfi
    let generatedAt: Date

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(json.utf8.count), countStyle: .file)
    }
}

private enum GroupDetailsActionError: LocalizedError {
    case noActiveAccount

    var errorDescription: String? {
        switch self {
        case .noActiveAccount:
            L10n.string("No active account is selected.")
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

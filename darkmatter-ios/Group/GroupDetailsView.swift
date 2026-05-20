import SwiftUI
import MarmotKit

/// Inspector for a single group. Roster, invite/remove, leave.
struct GroupDetailsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: ConversationViewModel

    @State private var showAddMembers = false
    @State private var showLeaveConfirm = false
    @State private var actionError: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AvatarBubble(seed: viewModel.group.groupIdHex, title: viewModel.displayTitle)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.displayTitle)
                            .font(.title3.weight(.semibold))
                        if !viewModel.group.description.isEmpty {
                            Text(viewModel.group.description)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }

            Section {
                LabeledContent("Group ID") {
                    Text(IdentityFormatter.short(viewModel.group.groupIdHex))
                        .font(.system(.caption, design: .monospaced))
                }
                LabeledContent("Members", value: "\(viewModel.members.count)")
                LabeledContent("Relays", value: "\(viewModel.group.relays.count)")
            }

            Section("Roster") {
                ForEach(viewModel.members, id: \.memberIdHex) { member in
                    GroupMemberRow(
                        member: member,
                        isAdmin: viewModel.group.admins.contains(member.memberIdHex)
                            || (member.account.map { viewModel.group.admins.contains($0) } ?? false)
                    )
                    .swipeActions(edge: .trailing) {
                        if !member.local {
                            Button(role: .destructive) {
                                Task { await remove(member: member) }
                            } label: {
                                Label("Remove", systemImage: "person.crop.circle.badge.minus")
                            }
                        }
                    }
                }

                Button {
                    showAddMembers = true
                } label: {
                    Label("Add Members", systemImage: "person.crop.circle.badge.plus")
                }
            }

            Section {
                Button(role: .destructive) {
                    showLeaveConfirm = true
                } label: {
                    Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity)
                }
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
            AddMembersSheet(onSubmit: { refs in await invite(refs: refs) })
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
            Text("You'll stop receiving messages from this group. Other members will see a system message.")
        }
    }

    // MARK: - Actions

    private func invite(refs: [String]) async {
        guard let accountRef = appState.activeAccountRef else { return }
        do {
            _ = try await appState.marmot.inviteMembers(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex,
                memberRefs: refs
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func remove(member: AppGroupMemberRecordFfi) async {
        guard let accountRef = appState.activeAccountRef else { return }
        let target = member.account ?? member.memberIdHex
        do {
            _ = try await appState.marmot.removeMembers(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex,
                memberRefs: [target]
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func leave() async {
        guard let accountRef = appState.activeAccountRef else { return }
        do {
            _ = try await appState.marmot.leaveGroup(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex
            )
            dismiss()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

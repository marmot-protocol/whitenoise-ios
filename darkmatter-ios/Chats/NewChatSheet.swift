import SwiftUI
import MarmotKit

/// Compose a new MLS group. Add one or more recipients by profile reference.
/// Optional group name — auto-omitted for 2-member groups so the chats list
/// renders them as DMs.
struct NewChatSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var model = NewChatSheetViewModel()

    private var canSubmit: Bool {
        !model.members.isEmpty && !model.isCreating && appState.activeAccountRef != nil
    }

    static func normalizedGroupName(_ raw: String) -> String {
        ProfileSanitizer.groupName(raw) ?? ""
    }

    static func normalizedGroupDescription(_ raw: String) -> String? {
        ProfileSanitizer.multilineText(raw, maxLength: ProfileSanitizer.maxGroupDescriptionLength)
    }

    typealias PendingMemberAddResult = AddMembersPresentation.PendingMemberAddResult
    typealias NormalizedMemberResult = AddMembersPresentation.NormalizedMemberResult

    static func normalizedMember(
        _ raw: String,
        normalize: (String) async throws -> MemberRefFfi
    ) async -> NormalizedMemberResult {
        await AddMembersPresentation.normalizedMember(raw, normalize: normalize)
    }

    static func stage(
        _ normalized: MemberRefFfi,
        existingMembers: [MemberRefFfi]
    ) -> PendingMemberAddResult {
        AddMembersPresentation.stage(normalized, existingMembers: existingMembers)
    }

    var body: some View {
        @Bindable var model = model
        return NavigationStack {
            Form {
                Section("Recipients") {
                    ForEach(model.members, id: \.accountIdHex) { member in
                        HStack {
                            StagedGroupMemberRow(member: member)
                            Button(role: .destructive) {
                                model.members.removeAll { $0.accountIdHex == member.accountIdHex }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        TextField("npub1…, nprofile1…, or hex public key", text: $model.pendingMember)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                        Button {
                            Task { await model.addPending(using: appState) }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.tint)
                        }
                        .disabled(model.pendingMember.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    Button {
                        model.error = nil
                        model.showScanner = true
                    } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    }
                }

                Section("Optional") {
                    TextField("Group name", text: $model.groupName)
                    TextField("Description", text: $model.groupDescription, axis: .vertical)
                        .lineLimit(2...4)
                }

                if let error = model.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await model.create(using: appState, dismiss: { dismiss() }) }
                    }
                    .disabled(!canSubmit)
                }
            }
            .interactiveDismissDisabled(model.isCreating)
            .fullScreenCover(isPresented: $model.showScanner) {
                ScannerSheet { result in
                    model.showScanner = false
                    model.handleScan(result, using: appState)
                }
                .appAppearance()
            }
        }
    }
}

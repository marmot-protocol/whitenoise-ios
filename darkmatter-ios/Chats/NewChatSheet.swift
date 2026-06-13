import SwiftUI
import MarmotKit

/// Compose a new MLS group. Add one or more recipients by profile reference.
/// Optional group name — auto-omitted for 2-member groups so the chats list
/// renders them as DMs.
struct NewChatSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var members: [MemberRefFfi] = []
    @State private var pendingMember: String = ""
    @State private var groupName: String = ""
    @State private var description: String = ""
    @State private var isCreating = false
    @State private var error: String?
    @State private var showScanner = false

    private var canSubmit: Bool {
        !members.isEmpty && !isCreating && appState.activeAccountRef != nil
    }

    static func normalizedGroupName(_ raw: String) -> String {
        ProfileSanitizer.groupName(raw) ?? ""
    }

    static func normalizedGroupDescription(_ raw: String) -> String? {
        ProfileSanitizer.multilineText(raw, maxLength: ProfileSanitizer.maxGroupDescriptionLength)
    }

    typealias PendingMemberAddResult = AddMembersPresentation.PendingMemberAddResult

    static func pendingMemberAddResult(
        _ raw: String,
        existingMembers: [MemberRefFfi],
        normalize: (String) throws -> MemberRefFfi
    ) -> PendingMemberAddResult {
        AddMembersPresentation.pendingMemberAddResult(
            raw,
            existingMembers: existingMembers,
            normalize: normalize
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Recipients") {
                    ForEach(members, id: \.accountIdHex) { member in
                        HStack {
                            StagedGroupMemberRow(member: member)
                            Button(role: .destructive) {
                                members.removeAll { $0.accountIdHex == member.accountIdHex }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        TextField("npub1…, nprofile1…, or hex public key", text: $pendingMember)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                        Button {
                            addPending()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.tint)
                        }
                        .disabled(pendingMember.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    Button {
                        error = nil
                        showScanner = true
                    } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    }
                }

                Section("Optional") {
                    TextField("Group name", text: $groupName)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }

                if let error {
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
                        Task { await create() }
                    }
                    .disabled(!canSubmit)
                }
            }
            .interactiveDismissDisabled(isCreating)
            .fullScreenCover(isPresented: $showScanner) {
                ScannerSheet { result in
                    showScanner = false
                    handleScan(result)
                }
                .appAppearance()
            }
        }
    }

    @discardableResult
    private func addPending() -> Bool {
        add(
            pendingMember,
            invalidMessage: L10n.string("Enter a valid npub, nprofile, Nostr URI, profile link, or hex public key.")
        )
    }

    @discardableResult
    private func add(_ raw: String, invalidMessage: String) -> Bool {
        switch Self.pendingMemberAddResult(
            raw,
            existingMembers: members,
            normalize: { try appState.marmot.normalizeMemberRef(memberRef: $0) }
        ) {
        case .empty:
            return true
        case .duplicate:
            pendingMember = ""
            error = nil
            Haptics.selection()
            return true
        case .invalid:
            Haptics.error()
            error = invalidMessage
            return false
        case .added(let updatedMembers, let addedMember):
            members = updatedMembers
            pendingMember = ""
            error = nil
            Haptics.success()
            _ = appState.profile(forAccountIdHex: addedMember.accountIdHex)
            return true
        }
    }

    /// Add a recipient from a scanned profile QR code.
    private func handleScan(_ raw: String) {
        add(raw, invalidMessage: L10n.string("That QR code isn't a Dark Matter profile."))
    }

    @MainActor
    private func create() async {
        guard let accountRef = appState.activeAccountRef else { return }
        // Capture text still in the field before creating.
        guard addPending() else { return }

        isCreating = true
        error = nil
        do {
            let groupIdHex = try await appState.marmot.createGroup(
                accountRef: accountRef,
                name: Self.normalizedGroupName(groupName),
                memberRefs: members.map(\.memberRef),
                description: Self.normalizedGroupDescription(description)
            )
            Haptics.success()
            dismiss()
            appState.presentChat(groupIdHex: groupIdHex)
        } catch let marmotError as MarmotKitError {
            Haptics.error()
            if case .MissingKeyPackage(let account) = marmotError {
                // Soft validation — keep the sheet open and name who can't be added.
                self.error = L10n.formatted(
                    "%@ hasn't published a compatible key package, so they can't be added yet.",
                    IdentityFormatter.short(account)
                )
            } else {
                self.error = marmotError.localizedDescription
                appState.present(.error(L10n.string("Couldn't create chat"), message: marmotError.localizedDescription))
            }
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
            appState.present(.error(L10n.string("Couldn't create chat"), message: error.localizedDescription))
        }
        isCreating = false
    }
}

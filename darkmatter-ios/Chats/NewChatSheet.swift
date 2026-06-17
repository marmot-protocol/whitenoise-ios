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
                            Task { await addPending() }
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
    private func addPending() async -> Bool {
        await add(
            pendingMember,
            invalidMessage: L10n.string("Enter a valid npub, nprofile, Nostr URI, profile link, or hex public key.")
        )
    }

    @discardableResult
    private func add(_ raw: String, invalidMessage: String) async -> Bool {
        // Normalize off the MainActor; only hop back to mutate members/error (#260).
        let normalizedResult = await Self.normalizedMember(
            raw,
            normalize: { try await appState.currentMarmotClient().normalizeMemberRef(memberRef: $0) }
        )
        switch normalizedResult {
        case .empty:
            return true
        case .invalid:
            Haptics.error()
            error = invalidMessage
            return false
        case .normalized(let normalized):
            // Stage against the live members list (post-await) so concurrent
            // adds dedup correctly instead of racing on a stale snapshot.
            switch Self.stage(normalized, existingMembers: members) {
            case .empty, .invalid:
                return false
            case .duplicate:
                clearPendingIfUnchanged(raw)
                error = nil
                Haptics.selection()
                return true
            case .added(let updatedMembers, let addedMember):
                members = updatedMembers
                clearPendingIfUnchanged(raw)
                error = nil
                Haptics.success()
                _ = appState.profile(forAccountIdHex: addedMember.accountIdHex)
                return true
            }
        }
    }

    /// Clear the pending field only if it still holds the value we normalized,
    /// so an older add completing off-main can't erase text the user typed
    /// while the FFI was in flight (#260/#274).
    private func clearPendingIfUnchanged(_ raw: String) {
        if pendingMember == raw {
            pendingMember = ""
        }
    }

    /// Add a recipient from a scanned profile QR code.
    private func handleScan(_ raw: String) {
        Task { await add(raw, invalidMessage: L10n.string("That QR code isn't a Dark Matter profile.")) }
    }

    @MainActor
    private func create() async {
        // Take the in-flight guard synchronously before the first await so a
        // fast double-tap can't start two concurrent create tasks while the
        // off-main recipient normalization is still in flight (#260/#274).
        guard !isCreating else { return }
        guard let accountRef = appState.activeAccountRef else { return }
        isCreating = true
        error = nil
        // Capture text still in the field before creating.
        guard await addPending() else {
            isCreating = false
            return
        }
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

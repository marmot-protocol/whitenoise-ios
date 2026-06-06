import SwiftUI
import MarmotKit

/// Compose a new MLS group. Add one or more recipients by profile reference.
/// Optional group name — auto-omitted for 2-member groups so the chats list
/// renders them as DMs.
struct NewChatSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var members: [String] = []
    @State private var pendingMember: String = ""
    @State private var groupName: String = ""
    @State private var description: String = ""
    @State private var isCreating = false
    @State private var error: String?
    @State private var showScanner = false

    private var canSubmit: Bool {
        !members.isEmpty && !isCreating && appState.activeAccountRef != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Recipients") {
                    ForEach(members, id: \.self) { member in
                        HStack {
                            Text(IdentityFormatter.short(member))
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Button(role: .destructive) {
                                members.removeAll { $0 == member }
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

    private func addPending() {
        let trimmed = pendingMember.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let memberRef = AddMembersPresentation.memberRef(fromScannedPayload: trimmed) else {
            Haptics.error()
            error = L10n.string("Enter a valid npub, nprofile, Nostr URI, profile link, or hex public key.")
            return
        }
        guard !memberRef.isEmpty, !members.contains(memberRef) else { return }
        members.append(memberRef)
        pendingMember = ""
        error = nil
    }

    /// Add a recipient from a scanned profile QR code.
    private func handleScan(_ raw: String) {
        guard let memberRef = NostrProfileReference.memberRef(from: raw) else {
            error = L10n.string("That QR code isn't a Dark Matter profile.")
            Haptics.error()
            return
        }
        if !members.contains(memberRef) { members.append(memberRef) }
        Haptics.success()
    }

    @MainActor
    private func create() async {
        guard let accountRef = appState.activeAccountRef else { return }
        addPending() // in case the user hits Create with text still in the field

        isCreating = true
        error = nil
        do {
            let groupIdHex = try await appState.marmot.createGroup(
                accountRef: accountRef,
                name: groupName.trimmingCharacters(in: .whitespacesAndNewlines),
                memberRefs: members,
                description: description.isEmpty ? nil : description
            )
            Haptics.success()
            dismiss()
            appState.presentChat(groupIdHex: groupIdHex)
        } catch let marmotError as MarmotKitError {
            Haptics.error()
            if case .MissingKeyPackage(let account) = marmotError {
                // Soft validation — keep the sheet open and name who can't be added.
                self.error = L10n.string("\(IdentityFormatter.short(account)) hasn't published a compatible key package, so they can't be added yet.")
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

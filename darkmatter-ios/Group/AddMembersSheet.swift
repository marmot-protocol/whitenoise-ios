import SwiftUI
import MarmotKit

struct AddMembersSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let normalize: (String) throws -> MemberRefFfi
    let onSubmit: ([String]) async throws -> Void

    @State private var members: [MemberRefFfi] = []
    @State private var pending: String = ""
    @State private var isInviting = false
    @State private var error: String?
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Invite") {
                    ForEach(members, id: \.accountIdHex) { member in
                        HStack(spacing: 8) {
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
                        TextField("npub1…, nprofile1…, or hex public key", text: $pending)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                        Button {
                            addPending()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.tint)
                        }
                        .disabled(pending.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    Button {
                        error = nil
                        showScanner = true
                    } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    }
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isInviting ? L10n.string("Inviting…") : L10n.string("Invite")) {
                        Task { await invite() }
                    }
                    .disabled(members.isEmpty || isInviting)
                }
            }
            .interactiveDismissDisabled(isInviting)
            .fullScreenCover(isPresented: $showScanner) {
                ScannerSheet { result in
                    showScanner = false
                    addScanned(result)
                }
                .appAppearance()
            }
        }
    }

    private func add(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let memberRef = AddMembersPresentation.memberRef(fromScannedPayload: trimmed) else {
            Haptics.error()
            self.error = L10n.string("Enter a valid npub, nprofile, Nostr URI, profile link, or hex public key.")
            return
        }
        do {
            let normalized = try normalize(memberRef)
            guard !members.contains(where: { $0.accountIdHex == normalized.accountIdHex }) else {
                pending = ""
                error = nil
                Haptics.selection()
                return
            }
            members.append(normalized)
            pending = ""
            error = nil
            Haptics.success()
            _ = appState.profile(forAccountIdHex: normalized.accountIdHex)
        } catch {
            Haptics.error()
            self.error = L10n.string("Enter a valid npub, nprofile, Nostr URI, profile link, or hex public key.")
        }
    }

    private func addPending() {
        add(pending)
    }

    private func addScanned(_ raw: String) {
        guard let memberRef = AddMembersPresentation.memberRef(fromScannedPayload: raw) else {
            Haptics.error()
            self.error = L10n.string("Enter a valid npub, nprofile, Nostr URI, profile link, or hex public key.")
            return
        }
        add(memberRef)
    }

    private func invite() async {
        addPending()
        guard !members.isEmpty else { return }
        isInviting = true
        error = nil
        do {
            try await onSubmit(members.map(\.memberRef))
            isInviting = false
            dismiss()
        } catch {
            isInviting = false
            self.error = error.localizedDescription
        }
    }
}

struct StagedGroupMemberRow: View {
    @Environment(AppState.self) private var appState
    let member: MemberRefFfi

    var body: some View {
        HStack(spacing: 12) {
            AvatarBubble(
                seed: member.accountIdHex,
                title: displayName,
                pictureURL: appState.avatarURL(forAccountIdHex: member.accountIdHex)
            )
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.body)
                Text(AddMembersPresentation.secondaryIdentity(for: member))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }

    private var displayName: String {
        AddMembersPresentation.displayName(for: member, appState: appState)
    }
}

enum AddMembersPresentation {
    static func memberRef(fromScannedPayload raw: String) -> String? {
        NostrProfileReference.memberRef(from: raw)
    }

    @MainActor
    static func displayName(for member: MemberRefFfi, appState: AppState) -> String {
        appState.knownDisplayName(forAccountIdHex: member.accountIdHex)
            ?? IdentityFormatter.short(member.accountIdHex)
    }

    static func secondaryIdentity(for member: MemberRefFfi) -> String {
        IdentityFormatter.short(member.npub)
    }
}

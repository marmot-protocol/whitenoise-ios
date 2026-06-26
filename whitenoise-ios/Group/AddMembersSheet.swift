import SwiftUI
import MarmotKit

struct AddMembersSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let normalize: (String) async throws -> MemberRefFfi
    let onSubmit: ([String]) async throws -> Void

    @State private var model = AddMembersSheetViewModel()

    var body: some View {
        @Bindable var model = model
        @Bindable var recipients = model.recipients
        return NavigationStack {
            Form {
                Section("Invite") {
                    ForEach(recipients.members, id: \.accountIdHex) { member in
                        HStack(spacing: 8) {
                            StagedGroupMemberRow(member: member)

                            Button(role: .destructive) {
                                recipients.members.removeAll { $0.accountIdHex == member.accountIdHex }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        TextField("npub1…, nprofile1…, or hex public key", text: $recipients.pending)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: recipients.pending) {
                                Task { await model.autoStagePending(normalize: normalize, using: appState) }
                            }
                            .onSubmit {
                                Task { await model.addPending(normalize: normalize, using: appState) }
                            }
                        Button {
                            Task { await model.addPending(normalize: normalize, using: appState) }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.tint)
                        }
                        .disabled(recipients.pending.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    Button {
                        recipients.error = nil
                        recipients.showScanner = true
                    } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    }
                }

                if let error = recipients.error {
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
                    Button(model.isInviting ? L10n.string("Inviting…") : L10n.string("Invite")) {
                        Task { await model.invite(normalize: normalize, onSubmit: onSubmit, using: appState, dismiss: { dismiss() }) }
                    }
                    .disabled(
                        model.isInviting ||
                        (recipients.members.isEmpty && recipients.pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    )
                }
            }
            .interactiveDismissDisabled(model.isInviting)
            .fullScreenCover(isPresented: $recipients.showScanner) {
                ScannerSheet { result in
                    recipients.showScanner = false
                    model.addScanned(result, normalize: normalize, using: appState)
                }
                .appAppearance()
            }
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
    enum PendingMemberAddResult: Equatable {
        case empty
        case invalid
        case duplicate
        case added([MemberRefFfi], MemberRefFfi)
    }

    /// Outcome of normalizing a raw recipient reference off the main actor,
    /// before it is staged against the live member list.
    enum NormalizedMemberResult: Equatable {
        case empty
        case invalid
        case normalized(MemberRefFfi)
    }

    /// True when `raw` already parses to a complete, valid profile reference
    /// (npub/nprofile with a good checksum, or 64-char hex). Lets the input
    /// field decide whether to auto-stage without flashing errors while a
    /// partial reference is still being typed. Synchronous — no Marmot hop.
    static func isCompleteReference(_ raw: String) -> Bool {
        memberRef(fromScannedPayload: raw) != nil
    }

    static func memberRef(fromScannedPayload raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if case .profile(let memberRef) = DeepLink.parse(string: trimmed) {
            return memberRef
        }
        return NostrProfileReference.memberRef(fromReference: trimmed)
    }

    /// Parses and normalizes a raw recipient reference. The `normalize` closure
    /// is expected to run the synchronous MarmotKit FFI off the main actor
    /// (#260), so callers can `await` this and only hop back to the MainActor
    /// to stage the result.
    static func normalizedMember(
        _ raw: String,
        normalize: (String) async throws -> MemberRefFfi
    ) async -> NormalizedMemberResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let memberRef = memberRef(fromScannedPayload: trimmed) else {
            return .invalid
        }
        do {
            return .normalized(try await normalize(memberRef))
        } catch {
            return .invalid
        }
    }

    /// Stages a normalized member against the current member list. Pure and
    /// MainActor-cheap: callers run this after awaiting `normalizedMember` so
    /// the dedup check sees the live `members` value rather than a snapshot
    /// captured before the off-main hop.
    static func stage(
        _ normalized: MemberRefFfi,
        existingMembers: [MemberRefFfi]
    ) -> PendingMemberAddResult {
        guard !existingMembers.contains(where: { $0.accountIdHex == normalized.accountIdHex }) else {
            return .duplicate
        }
        return .added(existingMembers + [normalized], normalized)
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

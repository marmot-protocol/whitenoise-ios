import SwiftUI
import MarmotKit

nonisolated enum ProfileReferenceResolution {
    static func referenceForResolution(_ raw: String) -> String? {
        guard NostrProfileReference.isWithinReferenceLimit(raw) else { return nil }
        let reference = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return nil }
        return reference
    }
}

/// Read-only profile shown when you scan someone's QR or open a profile deep
/// link. Resolves the profile reference to an account id, enriches with
/// cached/fetched kind:0 metadata, and offers a "Message" action that starts
/// a 2-member group with them.
struct ProfileView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let npub: String

    @State private var model = ProfileViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer(minLength: 12)

                AvatarBubble(
                    seed: model.hex ?? npub,
                    title: title,
                    pictureURL: model.hex.flatMap { appState.avatarURL(forAccountIdHex: $0) }
                )
                .frame(width: 96, height: 96)

                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Button(action: copyProfileReference) {
                    HStack(spacing: 8) {
                        Text(model.copied ? L10n.string("Copied") : IdentityFormatter.short(displayReference))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(model.copied ? Color.green : Color.secondary)
                        Image(systemName: model.copied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(model.copied ? Color.green : Color.accentColor)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                if model.hex == nil {
                    Label("Couldn't read this profile code.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Button {
                    Task { await model.message(npub: npub, title: title, using: appState, dismiss: { dismiss() }) }
                } label: {
                    HStack {
                        if model.creating { ProgressView().controlSize(.small) }
                        Label("Message", systemImage: "bubble.left.and.bubble.right.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)
                .disabled(model.creating || model.hex == nil || appState.activeAccountRef == nil || isSelf)
            }
            .padding(.bottom, 16)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.resolve(npub: npub, using: appState) }
        }
    }

    private var title: String {
        if let hex = model.hex { return appState.displayName(forAccountIdHex: hex) }
        return IdentityFormatter.short(npub)
    }

    private var displayReference: String {
        if let hex = model.hex { return appState.npub(forAccountIdHex: hex) }
        return npub
    }

    private var isSelf: Bool {
        guard let hex = model.hex else { return false }
        return appState.accounts.contains { $0.accountIdHex == hex }
    }

    private func copyProfileReference() {
        UIPasteboard.general.string = displayReference
        Haptics.selection()
        withAnimation(.smooth(duration: 0.15)) { model.copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.smooth(duration: 0.2)) { model.copied = false }
        }
    }
}

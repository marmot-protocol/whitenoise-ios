import SwiftUI
import MarmotKit

struct ContactNicknameRow: View {
    @Environment(AppState.self) private var appState
    let accountIdHex: String

    @State private var isEditing = false
    @State private var draft = ""
    @State private var editingOwner: String?
    @State private var editingContact: String?

    var body: some View {
        Button {
            editingOwner = ownerAccountIdHex
            editingContact = accountIdHex
            draft = nickname ?? ""
            isEditing = true
        } label: {
            HStack {
                Label("Nickname", systemImage: "pencil")
                Spacer()
                Text(nickname ?? L10n.string("None"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
        }
        .disabled(ownerAccountIdHex == nil)
        .alert(nickname == nil ? L10n.string("Set nickname") : L10n.string("Edit nickname"), isPresented: $isEditing) {
            TextField(L10n.string("Nickname"), text: $draft)
            Button("Save") {
                guard let editingOwner, editingOwner == ownerAccountIdHex,
                      editingContact == accountIdHex else { return }
                appState.setContactNickname(draft, forAccountIdHex: accountIdHex)
                Haptics.selection()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only you see this on this device. Clearing it restores their profile name.")
        }
        .onChange(of: ownerAccountIdHex) { _, _ in isEditing = false }
        .onChange(of: accountIdHex) { _, _ in isEditing = false }
    }

    private var nickname: String? {
        appState.contactNickname(forAccountIdHex: accountIdHex)
    }

    private var ownerAccountIdHex: String? {
        AppState.contactNicknameOwner(
            activeAccountIdHex: appState.activeAccount?.accountIdHex,
            localAccountIdsHex: appState.accounts.map(\.accountIdHex),
            contactAccountIdHex: accountIdHex
        )
    }
}

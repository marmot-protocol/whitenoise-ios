import SwiftUI
import MarmotKit

/// Compose a new MLS group. Add one or more recipients by npub (or hex
/// account id). Optional group name — auto-omitted for 2-member groups so
/// the chats list renders them as DMs.
struct NewChatSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var members: [String] = []
    @State private var pendingMember: String = ""
    @State private var groupName: String = ""
    @State private var description: String = ""
    @State private var isCreating = false
    @State private var error: String?

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
                        TextField("npub1… or hex account id", text: $pendingMember)
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
        }
    }

    private func addPending() {
        let trimmed = pendingMember.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !members.contains(trimmed) else { return }
        members.append(trimmed)
        pendingMember = ""
    }

    @MainActor
    private func create() async {
        guard let accountRef = appState.activeAccountRef else { return }
        addPending() // in case the user hits Create with text still in the field

        isCreating = true
        error = nil
        do {
            _ = try await appState.marmot.createGroup(
                accountRef: accountRef,
                name: groupName.trimmingCharacters(in: .whitespacesAndNewlines),
                memberRefs: members,
                description: description.isEmpty ? nil : description
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isCreating = false
    }
}

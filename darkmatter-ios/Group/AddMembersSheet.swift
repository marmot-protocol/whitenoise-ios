import SwiftUI

struct AddMembersSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSubmit: ([String]) async -> Void

    @State private var members: [String] = []
    @State private var pending: String = ""
    @State private var isInviting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Invite") {
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
                        TextField("npub1… or hex account id", text: $pending)
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
                    Button(isInviting ? "Inviting…" : "Invite") {
                        Task { await invite() }
                    }
                    .disabled(members.isEmpty || isInviting)
                }
            }
            .interactiveDismissDisabled(isInviting)
        }
    }

    private func addPending() {
        let trimmed = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !members.contains(trimmed) else { return }
        members.append(trimmed)
        pending = ""
    }

    private func invite() async {
        addPending()
        guard !members.isEmpty else { return }
        isInviting = true
        error = nil
        await onSubmit(members)
        isInviting = false
        dismiss()
    }
}

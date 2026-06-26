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
        !model.recipients.members.isEmpty && !model.isCreating && appState.activeAccountRef != nil
    }

    static func normalizedGroupName(_ raw: String) -> String {
        ProfileSanitizer.groupName(raw) ?? ""
    }

    static func normalizedGroupDescription(_ raw: String) -> String? {
        ProfileSanitizer.multilineText(raw, maxLength: ProfileSanitizer.maxGroupDescriptionLength)
    }

    var body: some View {
        @Bindable var model = model
        @Bindable var recipients = model.recipients
        return NavigationStack {
            Form {
                Section("Recipients") {
                    ForEach(recipients.members, id: \.accountIdHex) { member in
                        HStack {
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
                                Task { await model.autoStagePending(using: appState) }
                            }
                            .onSubmit {
                                Task { await model.addPending(using: appState) }
                            }
                        Button {
                            Task { await model.addPending(using: appState) }
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

                Section("Optional") {
                    TextField("Group name", text: $model.groupName)
                    TextField("Description", text: $model.groupDescription, axis: .vertical)
                        .lineLimit(2...4)
                }

                if let error = recipients.error {
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
            .fullScreenCover(isPresented: $recipients.showScanner) {
                ScannerSheet { result in
                    recipients.showScanner = false
                    model.handleScan(result, using: appState)
                }
                .appAppearance()
            }
        }
    }
}

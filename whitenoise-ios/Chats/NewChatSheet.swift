import SwiftUI
import MarmotKit

/// Compose a new MLS group. Add one or more members by profile reference.
/// Optional group name — auto-omitted for 2-member groups so the chats list
/// renders them as DMs.
struct NewChatSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var model = NewChatSheetViewModel()

    private var canSubmit: Bool {
        AddMembersPresentation.canCreate(
            stagedCount: model.memberPicker.members.count,
            isCreating: model.isCreating,
            hasActiveAccount: appState.activeAccountRef != nil
        )
    }

    static func normalizedGroupName(_ raw: String) -> String {
        ProfileSanitizer.groupName(raw) ?? ""
    }

    static func normalizedGroupDescription(_ raw: String) -> String? {
        ProfileSanitizer.multilineText(raw, maxLength: ProfileSanitizer.maxGroupDescriptionLength)
    }

    var body: some View {
        @Bindable var model = model
        return NavigationStack {
            Form {
                MemberPickerView(
                    model: model.memberPicker,
                    title: "Recipients",
                    normalize: { try await appState.currentMarmotClient().normalizeMemberRef(memberRef: $0) },
                    scanInvalidMessage: L10n.string("That QR code isn't a White Noise profile.")
                )

                Section("Optional") {
                    TextField("Group name", text: $model.groupName)
                    TextField("Description", text: $model.groupDescription, axis: .vertical)
                        .lineLimit(2...4)
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
        }
    }
}

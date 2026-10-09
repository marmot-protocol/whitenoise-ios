import SwiftUI

struct GroupInfoEditSheet<CurrentAvatar: View>: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: GroupDetailsViewModel
    let hasCurrentImage: Bool
    let showsCurrentAvatar: Bool
    @ViewBuilder var currentAvatar: () -> CurrentAvatar

    @State private var photoMenuAction: WNPhotoMenuAction?
    @State private var progressPhase: GroupImageProgressPhase?
    @State private var saveError: String?
    @State private var isSaving = false

    private var isBusy: Bool { isSaving || model.membershipActionInFlight }

    var body: some View {
        NavigationStack {
            Form {
                GroupInfoFormSections(
                    name: $model.renameDraft,
                    description: $model.descriptionDraft,
                    namePlaceholder: L10n.string("Group name"),
                    hasPhoto: model.imageEdit.hasPhoto(hasCurrentImage: hasCurrentImage),
                    photoMenuAction: $photoMenuAction,
                    photoProgressLabel: progressPhase?.label,
                    isDisabled: isBusy
                ) {
                    switch model.imageEdit {
                    case .replaced(let draft):
                        WNAvatarPreview(name: model.renameDraft, image: draft.thumbnail, emptySystemImage: "person.2")
                    case .unchanged where showsCurrentAvatar:
                        currentAvatar()
                            .aspectRatio(1, contentMode: .fit)
                    case .unchanged, .removed:
                        WNAvatarPreview(name: model.renameDraft, emptySystemImage: "person.2")
                    }
                } footer: {
                    Text("Everyone in the group will see this name and description. Leave the description blank to remove it.")
                }

                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit Group Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    WNButton(title: "Cancel", emphasis: .secondary, size: .compact) {
                        dismiss()
                    }
                    .disabled(isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    WNButton(title: "Save", size: .compact, isLoading: isSaving, action: save)
                        .disabled(isBusy || !model.canSaveGroupInfo)
                }
            }
            .wnPhotoSourceMenu(
                selection: $photoMenuAction,
                confirmsPublicUpload: false,
                prepareDraft: { data, fileName, sourceURL in
                    try await GroupImageDraftProcessor.prepare(
                        data: data,
                        fileName: fileName,
                        typeIdentifier: AvatarImageCropper.outputTypeIdentifier,
                        sourceURL: sourceURL
                    )
                },
                onRemove: { model.imageEdit = .removing(hasCurrentImage: hasCurrentImage) },
                onSelect: { draft in
                    model.imageEdit = .replaced(draft)
                    Haptics.selection()
                }
            )
        }
        .interactiveDismissDisabled(isBusy)
    }

    private func save() {
        saveError = nil
        isSaving = true
        Task {
            defer {
                isSaving = false
                progressPhase = nil
            }
            if await model.saveGroupInfo(using: appState, onProgress: { progressPhase = $0 }) {
                dismiss()
            } else {
                saveError = model.actionError
            }
        }
    }
}

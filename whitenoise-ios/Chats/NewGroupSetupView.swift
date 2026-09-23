import SwiftUI
import MarmotKit

/// Step two of New Group: image, metadata, disappearing-messages preset, and
/// a review of the selected people. Group-name semantics are unchanged — an
/// unnamed group with one member renders as a direct message.
struct NewGroupSetupView: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: NewChatFlowViewModel
    let onOpen: (String) -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var retentionSeconds: UInt64 = 0
    @State private var showRetentionPicker = false
    @State private var groupImage: GroupImageUploadDraft?
    @State private var showPhotoMenu = false
    @State private var isPreparingImage = false
    @State private var imageError: String?

    var body: some View {
        Form {
            Section {
                VStack(spacing: 0) {
                    WNAvatarPhotoMenu(
                        hasPhoto: groupImage != nil,
                        isPresented: $showPhotoMenu
                    ) {
                        WNAvatarPreview(
                            name: name,
                            image: groupImage?.thumbnail,
                            emptySystemImage: "person.2"
                        )
                    }
                    .disabled(model.isCreatingGroup || isPreparingImage)

                    if isPreparingImage {
                        ProgressView(GroupImageProgressPhase.preparing.label)
                            .font(.footnote)
                            .padding(.top)
                    }

                    if let imageError {
                        Text(imageError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.top)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Section {
                TextField(
                    model.groupSelection.isEmpty
                        ? L10n.string("Group name")
                        : L10n.string("Group name (optional)"),
                    text: $name
                )
                    .textContentType(.organizationName)
                    .disabled(model.isCreatingGroup)

                TextField(
                    L10n.string("Description"),
                    text: $description,
                    axis: .vertical
                )
                .lineLimit(2...5)
                .disabled(model.isCreatingGroup)
            } header: {
                Text("Group Details")
            } footer: {
                if model.groupSelection.isEmpty {
                    Text("A group name is required when creating it without members.")
                } else {
                    Text("Groups without a name show their members instead.")
                }
            }

            Section {
                Button {
                    showRetentionPicker = true
                } label: {
                    LabeledContent("Disappearing messages") {
                        HStack(spacing: 6) {
                            Text(GroupRetentionPresentation.label(seconds: retentionSeconds))
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(model.isCreatingGroup)
            }

            Section("People") {
                if model.groupSelection.isEmpty {
                    Label("You can add members after creating the group.", systemImage: "person.badge.plus")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.groupSelection.members, id: \.accountIdHex) { member in
                        RecipientRow(accountIdHex: member.accountIdHex) {
                            EmptyView()
                        }
                    }
                }
            }

            if let error = model.groupCreateError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Set Up Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .navigationDestination(isPresented: $showRetentionPicker) {
            RetentionPresetPickerView(selection: $retentionSeconds)
        }
        .wnPhotoSourceMenu(
            isPresented: $showPhotoMenu,
            hasPhoto: groupImage != nil,
            // The selected bytes ride the encrypted group-image component, so
            // nothing here is published to a public host.
            confirmsPublicUpload: false,
            onError: { imageError = UserFacingError.message(for: $0) },
            onRemove: {
                imageError = nil
                groupImage = nil
            },
            onSelect: prepareImage
        )
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                WNButton(
                    title: model.isCreatingGroup ? "Creating…" : "Create",
                    size: .compact,
                    isLoading: model.isCreatingGroup
                ) {
                    Task {
                        await model.createGroup(
                            name: name,
                            description: description,
                            retentionSeconds: retentionSeconds,
                            image: groupImage,
                            using: appState,
                            onOpen: onOpen
                        )
                    }
                }
                .disabled(!canCreate)
            }
        }
        .navigationBarBackButtonHidden(model.isCreatingGroup)
    }

    private func prepareImage(_ selection: WNPhotoSourceSelection) {
        imageError = nil
        isPreparingImage = true
        Task {
            defer { isPreparingImage = false }
            do {
                groupImage = try await GroupImageDraftProcessor.prepare(
                    data: selection.data,
                    fileName: selection.fileName,
                    typeIdentifier: selection.typeIdentifier,
                    sourceURL: selection.sourceURL
                )
                Haptics.selection()
            } catch {
                imageError = UserFacingError.message(for: error)
                Haptics.error()
            }
        }
    }

    private var canCreate: Bool {
        AddMembersPresentation.canCreate(
            stagedCount: model.groupSelection.count,
            hasUsableName: !NewGroupPresentation.normalizedName(name).isEmpty,
            isCreating: model.isCreatingGroup,
            isPreparingImage: isPreparingImage,
            hasActiveAccount: appState.activeAccountRef != nil
        )
    }
}

/// Preset picker for the create flow: no prune warning needed because the
/// group doesn't exist yet. Custom durations stay in the details editor.
struct RetentionPresetPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: UInt64

    var body: some View {
        Form {
            Section {
                ForEach(GroupRetentionPresentation.presetSeconds, id: \.self) { seconds in
                    Button {
                        selection = seconds
                        dismiss()
                    } label: {
                        HStack {
                            Text(GroupRetentionPresentation.label(seconds: seconds))
                                .foregroundStyle(.primary)
                            Spacer()
                            if selection == seconds {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text(selection == 0
                    ? "Messages are kept until you delete them."
                    : "Messages are deleted for everyone after the selected time.")
            }
        }
        .navigationTitle("Disappearing messages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
    }
}

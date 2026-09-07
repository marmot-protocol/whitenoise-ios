import PhotosUI
import MarmotKit
import SwiftUI
import UniformTypeIdentifiers

struct CreateIdentityView: View {
    var showsCloseButton = false

    var body: some View {
        IdentityProfileSetupView(showsCloseButton: showsCloseButton)
    }
}

/// Shared profile form for sign-up and an optional imported-account update.
struct IdentityProfileSetupView: View {
    private enum PendingPhotoSource {
        case photos
        case files
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var model = CreateIdentityViewModel()
    @State private var pendingPhotoSource: PendingPhotoSource?
    @State private var showAvatarDisclosure = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showWebImagePicker = false
    @State private var cropSource: AvatarImageCropSource?
    @State private var isKeyboardVisible = false
    @FocusState private var nameFocused: Bool
    @FocusState private var aboutFocused: Bool

    let showsCloseButton: Bool
    let accountSetup: AccountSetupModel?
    @State private var setupSaveError: String?
    @State private var hasSubmittedProfile = false

    init(showsCloseButton: Bool = false, accountSetup: AccountSetupModel? = nil) {
        self.showsCloseButton = showsCloseButton
        self.accountSetup = accountSetup
    }

    private var isSaving: Bool { model.isSavingProfile || (accountSetup?.isBusy ?? false) }
    private var isBusy: Bool { model.isBusy || (accountSetup?.isBusy ?? false) }
    private var allowsBackNavigation: Bool {
        accountSetup == nil ? model.allowsBackNavigation : !isSaving
    }

    var body: some View {
        @Bindable var model = model

        Form {
            avatarSection
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            Section {
                WNInput(
                    placeholder: L10n.string("Name"),
                    text: $model.displayName,
                    submitLabel: .next,
                    autocapitalization: .words,
                    disablesAutocorrection: false,
                    focus: $nameFocused,
                    onSubmit: { aboutFocused = true }
                )
                .textContentType(.name)
                .wnInputRow()
            } header: {
                Text("Name").wnSectionHeader()
            }

            Section {
                WNInput(
                    placeholder: L10n.string("A little about you"),
                    text: $model.about,
                    kind: .multiline(3 ... 6),
                    autocapitalization: .sentences,
                    disablesAutocorrection: false,
                    focus: $aboutFocused
                )
                .accessibilityLabel("About")
                .wnInputRow()
            } header: {
                Text("About").wnSectionHeader()
            }

            if let failureMessage = setupSaveError ?? model.failureMessage {
                Section {
                    Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .disabled(isSaving || accountSetup?.isResumingProfilePublication == true)
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .dismissesKeyboardOnTap()
        .navigationTitle(accountSetup == nil ? "Sign Up" : "Update profile")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(!allowsBackNavigation)
        .toolbar {
            if showsCloseButton && allowsBackNavigation {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .interactiveDismissDisabled(!allowsBackNavigation)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if accountSetup != nil || !isKeyboardVisible {
                VStack(spacing: 8) {
                    WNButton(
                        title: LocalizedStringKey(primaryActionTitle),
                        isLoading: isSaving || model.isSubmitting
                    ) {
                        nameFocused = false
                        aboutFocused = false
                        Task {
                            if let accountSetup {
                                await saveImportedProfile(using: accountSetup)
                            } else if model.phase == .creationFailed {
                                await model.prepare(using: appState)
                            } else {
                                await model.submit(using: appState, dismiss: { dismiss() })
                            }
                        }
                    }
                    .disabled(isBusy || !hasValidName || (accountSetup != nil && accountSetup?.isConnected != true))
                    .accessibilityLabel(primaryActionTitle)
                    .accessibilityIdentifier(accountSetup == nil ? "sign-up.create" : "account-setup.save-profile")
                    .accessibilityValue(isSaving || model.isSubmitting ? "In progress" : "")

                    if accountSetup != nil {
                        Text("Saving publishes these details to your public profile.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    if accountSetup == nil && model.phase == .profileSaveFailed {
                        Button("Continue") {
                            Task {
                                await model.continueWithoutSaving(
                                    using: appState,
                                    dismiss: { dismiss() }
                                )
                            }
                        }
                        .controlSize(.large)
                        .disabled(model.isBusy)
                    }
                }
                .safeAreaPadding(.horizontal)
                .padding(.vertical)
                .safeAreaPadding(.bottom)
                .background(Color(.systemBackground))
            }
        }
        .trackKeyboardVisibility($isKeyboardVisible)
        .onChange(of: accountSetup?.snapshot.steps.first(where: { $0.step == .profile })?.status) {
            if hasSubmittedProfile, accountSetup?.snapshot.steps.first(where: { $0.step == .profile })?.status == .passed {
                dismiss()
            }
        }
        .task {
            if let profile = accountSetup?.snapshot.proposal?.profile {
                model.displayName = profile.displayName ?? profile.name ?? ""
                model.about = profile.about ?? ""
            } else if accountSetup == nil {
                await model.prepare(using: appState)
            }
        }
        .alert("Your avatar is public", isPresented: $showAvatarDisclosure) {
            Button("Continue") {
                switch pendingPhotoSource {
                case .photos:
                    showPhotoPicker = true
                case .files:
                    showFileImporter = true
                case nil:
                    break
                }
                pendingPhotoSource = nil
            }
            Button("Cancel", role: .cancel) {
                pendingPhotoSource = nil
            }
        } message: {
            Text("The photo is uploaded to a public service, and removing it from your profile may not delete the uploaded copy.")
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPickerView(
                selectionLimit: 1,
                filter: .images,
                onSelection: { selections in
                    guard let selection = selections.first else { return }
                    cropSource = AvatarImageCropSource(
                        data: selection.data,
                        fileName: selection.fileName,
                        typeIdentifier: selection.typeIdentifier,
                        sourceURL: nil
                    )
                },
                onError: model.setAvatarPreparationError,
                onDismiss: { showPhotoPicker = false }
            )
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            prepareImportedFile(result)
        }
        .sheet(isPresented: $showWebImagePicker) {
            OnboardingAvatarWebImagePicker { url in
                prepareWebImage(url)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $cropSource) { source in
            AvatarImageCropEditor(source: source) { source, croppedData in
                Task {
                    await model.prepareAvatar(
                        data: croppedData,
                        fileName: source.fileName,
                        typeIdentifier: "public.jpeg"
                    )
                }
            }
        }
        .background {
            Color(.systemBackground)
                .ignoresSafeArea()
        }
    }

    private var avatarSection: some View {
        VStack(spacing: 0) {
            WNAvatarPreview(
                name: model.displayName,
                image: model.avatarDraft?.thumbnail,
                pictureURL: ContentSanitizer.imageURL(accountSetup?.snapshot.proposal?.profile?.picture)
            )
            .containerRelativeFrame(.horizontal, count: 3, span: 1, spacing: 0)

            Menu {
                Button {
                    requestPhotoSource(.photos)
                } label: {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle")
                }

                Button {
                    requestPhotoSource(.files)
                } label: {
                    Label("Choose from Files", systemImage: "folder")
                }

                Button {
                    showWebImagePicker = true
                } label: {
                    Label("Find Image on Web", systemImage: "globe")
                }

                if model.avatarDraft != nil {
                    Divider()
                    Button("Remove Photo", systemImage: "trash", role: .destructive) {
                        model.setAvatarDraft(nil)
                    }
                }
            } label: {
                Text(model.avatarDraft == nil ? "Add Photo" : "Change Photo")
            }
            .wnAvatarActionButtonStyle()
            .padding(.top)
            .disabled(model.isPreparingAvatar)

            if model.isPreparingAvatar {
                ProgressView("Preparing Photo")
                    .font(.footnote)
                    .padding(.top)
            }

            if let avatarError = model.avatarError {
                Text(avatarError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top)
            }
        }
    }

    private func saveImportedProfile(using setup: AccountSetupModel) async {
        setupSaveError = nil
        let draft = OnboardingProfileMetadataDraft(
            displayName: model.displayName, about: model.about, uploadedPictureURL: nil
        )
        guard let profile = draft.merging(with: setup.snapshot.proposal?.profile) else { return }
        let avatar = model.avatarDraft.map { AccountSetupAvatar(data: $0.data, mediaType: $0.mediaType) }
        hasSubmittedProfile = true
        if await setup.saveProfile(profile, avatar: avatar) {
            Haptics.success()
            dismiss()
        } else {
            setupSaveError = setup.errorMessage ?? L10n.string("Couldn’t save your profile. Try again.")
            Haptics.error()
        }
    }

    private var primaryActionTitle: String {
        if let accountSetup {
            if isSaving { return L10n.string("Saving…") }
            return accountSetup.isResumingProfilePublication ? L10n.string("Retry") : L10n.string("Save")
        }
        if model.isSubmitting { return L10n.string("Signing Up…") }
        if model.phase == .creationFailed || model.phase == .profileSaveFailed {
            return L10n.string("Retry")
        }
        return L10n.string("Sign Up")
    }

    private var hasValidName: Bool {
        ContentSanitizer.displayName(model.displayName) != nil
    }

    private func requestPhotoSource(_ source: PendingPhotoSource) {
        pendingPhotoSource = source
        showAvatarDisclosure = true
    }

    private func prepareImportedFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await loadImportedFile(url) }
        case .failure(let error):
            model.setAvatarPreparationError(error)
        }
    }

    private func loadImportedFile(_ url: URL) async {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try AvatarImageCropper.boundedFileData(from: url)
            }.value
            cropSource = AvatarImageCropSource(
                data: data,
                fileName: url.lastPathComponent,
                typeIdentifier: nil,
                sourceURL: url
            )
        } catch {
            model.setAvatarPreparationError(error)
        }
    }

    private func prepareWebImage(_ url: URL) {
        Task {
            do {
                let data = try await RemoteImageFetch.imageData(for: url)
                cropSource = AvatarImageCropSource(
                    data: data,
                    fileName: url.lastPathComponent,
                    typeIdentifier: nil,
                    sourceURL: url
                )
            } catch {
                model.setAvatarPreparationError(error)
            }
        }
    }
}

import MarmotKit
import SwiftUI

struct CreateIdentityView: View {
    var isPushed = false

    var body: some View {
        IdentityProfileSetupView(isPushed: isPushed)
    }
}

/// Shared profile form for sign-up and an optional imported-account update.
struct IdentityProfileSetupView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var model = CreateIdentityViewModel()
    @State private var isFormReady: Bool
    @State private var submissionTask: Task<Void, Never>?
    @State private var showPhotoMenu = false
    @State private var isKeyboardVisible = false
    @State private var confirmsStartOver = false
    @State private var confirmsDiscardDraft = false
    @State private var discardDraftFailed = false
    @State private var isRestarting = false
    @State private var restartError: String?
    @State private var signUpFailure: CreateIdentityViewModel.Failure?
    @FocusState private var nameFocused: Bool
    @FocusState private var aboutFocused: Bool

    let isPushed: Bool
    let accountSetup: AccountSetupModel?
    @State private var setupSaveError: String?
    @State private var hasSubmittedProfile = false

    init(isPushed: Bool = false, accountSetup: AccountSetupModel? = nil) {
        self.isPushed = isPushed
        self.accountSetup = accountSetup
        _isFormReady = State(initialValue: accountSetup != nil)
    }

    private var importedProfileStatus: OnboardingStatusFfi? {
        accountSetup?.snapshot.steps.first { $0.step == .profile }?.status
    }

    private var isSaving: Bool { model.isSavingProfile || (accountSetup?.isBusy ?? false) }
    private var isBusy: Bool { isRestarting || model.isBusy || (accountSetup?.isBusy ?? false) }
    private var allowsBackNavigation: Bool {
        !isRestarting && (accountSetup == nil ? model.allowsBackNavigation : !isSaving)
    }

    private var profileEditor: some View {
        profileForm
        .disabled(isRestarting || model.isSubmitting || model.isResetting || isSaving || accountSetup?.isResumingProfilePublication == true)
        .formStyle(.grouped)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .wnPhotoSourceMenu(
            isPresented: $showPhotoMenu,
            hasPhoto: model.avatarDraft != nil,
            confirmsPublicUpload: true,
            onError: model.setAvatarPreparationError,
            onRemove: { model.setAvatarDraft(nil) },
            onSelect: { selection in
                Task {
                    await model.prepareAvatar(
                        data: selection.data,
                        fileName: selection.fileName,
                        typeIdentifier: selection.typeIdentifier
                    )
                }
            }
        )
    }

    private var presentedEditor: some View {
        Group {
            if isFormReady, model.isRestorationBlocked {
                restorationFailureView
            } else if isFormReady {
                profileEditor
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("Discard sign-up draft?", isPresented: $confirmsDiscardDraft) {
            Button("Discard draft", role: .destructive) {
                discardDraftFailed = false
                submissionTask = Task {
                    if await model.discardUnrestorableDraft() {
                        try? await appState.refreshAccounts(refreshUnreadSummaries: false)
                        dismiss()
                    } else {
                        discardDraftFailed = true
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only the saved sign-up form from this device. All accounts and anything already uploaded or published are kept.")
        }
        .alert(restartError == nil ? L10n.string("Start over?") : L10n.string("Couldn’t restart sign-up"),
               isPresented: $confirmsStartOver) {
            Button(restartError == nil ? L10n.string("Start over") : L10n.string("Retry"), role: .destructive, action: restartSignUp)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(restartError ?? L10n.string("This will discard your name, bio, photo, and unfinished account from this device. Anything already uploaded or published may remain online."))
        }
        .onChange(of: model.failure, initial: true) {
            if isFormReady, !model.isRestorationBlocked, let failure = model.failure { presentFailure(failure) }
        }
        .alert("Couldn’t add photo", isPresented: Binding(
            get: { model.avatarError != nil }, set: { if !$0 { model.clearAvatarError() } }
        )) {
            Button("Close", role: .cancel) {}
        } message: { Text(model.avatarError ?? "") }
        .alert(signUpFailure == .photoUpload ? L10n.string("Couldn’t upload photo") : L10n.string("Couldn’t finish sign-up"), isPresented: Binding(
            get: { signUpFailure != nil },
            set: { if !$0 { signUpFailure = nil } }
        ), presenting: signUpFailure) { failure in
            Button("Retry") { submitProfile() }
            Button(failure == .photoUpload ? L10n.string("Cancel") : L10n.string("Close"), role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
    }

    private var restorationFailureView: some View {
        ContentUnavailableView {
            Label("Couldn’t restore your unfinished sign-up. Please try again.", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Retry to read the saved draft again, or discard the draft without deleting any accounts.")
            if discardDraftFailed {
                Text("Couldn’t save your sign-up progress on this device. Free up some space and try again.")
            }
        } actions: {
            Button("Retry") {
                submissionTask = Task {
                    isRestarting = true
                    defer { isRestarting = false }
                    await appState.retrySignUpRestoration()
                    await prepareForm()
                }
            }
            Button("Discard draft", role: .destructive) { confirmsDiscardDraft = true }
        }
        .disabled(isBusy)
    }

    var body: some View {
        presentedEditor
        .onChange(of: model.displayName) { saveDraftChanges() }
        .onChange(of: model.about) { saveDraftChanges() }
        .onChange(of: model.avatarDraft) { saveDraftChanges() }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .dismissesKeyboardOnTap()
        .navigationTitle(accountSetup == nil ? "Sign Up" : "Update profile")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            if isFormReady && allowsBackNavigation {
                ToolbarItem(placement: .cancellationAction) {
                    WNIconButton(
                        title: isPushed ? "Back" : "Close",
                        systemImage: isPushed ? "chevron.backward" : "xmark",
                        chrome: .container
                    ) {
                        if accountSetup == nil { appState.closeSignUpDraft() }
                        dismiss()
                    }
                }
            }
            if isFormReady, accountSetup == nil, model.draft.requiresRecovery, !model.isResetPending, !model.isRestorationBlocked {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Start over", role: .destructive) {
                            nameFocused = false; aboutFocused = false
                            restartError = nil
                            confirmsStartOver = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                    .disabled(isBusy)
                }
            }
        }
        .interactiveDismissDisabled(!isFormReady || !allowsBackNavigation)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isFormReady && !model.isRestorationBlocked && (accountSetup != nil || !isKeyboardVisible) {
                profileActions
                    .safeAreaPadding(.horizontal, 16)
                    .safeAreaPadding(.bottom)
            }
        }
        // Native keyboard avoidance owns the motion; animating Form updates also morphs its rows.
        .onDisappear { submissionTask?.cancel() }
        .onChange(of: scenePhase) {
            if scenePhase == .background { submissionTask?.cancel() }
        }
        .trackKeyboardVisibility($isKeyboardVisible)
        .onChange(of: importedProfileStatus) {
            if hasSubmittedProfile, importedProfileStatus == .passed {
                dismiss()
            }
        }
        .task(id: accountSetup == nil ? scenePhase : .active) {
            await prepareForm()
        }
        .background {
            Color(.systemBackground)
                .ignoresSafeArea()
        }
    }

    private func prepareForm() async {
        guard accountSetup != nil || scenePhase == .active else { return }
        if let profile = accountSetup?.snapshot.proposal?.profile {
            model.displayName = profile.displayName ?? profile.name ?? ""
            model.about = profile.about ?? ""
        } else if accountSetup == nil {
            await appState.openSignUpDraft()
            let preparedModel = appState.signUpModel
            if preparedModel.isResetPending { isFormReady = false }
            await preparedModel.prepare(using: appState)
            guard !Task.isCancelled else { return }
            await preparedModel.persistDraft()
            guard !Task.isCancelled else { return }
            // Reveal the model only after reset cleanup and name preparation settle.
            model = preparedModel
            isFormReady = true
            if !model.isRestorationBlocked, let failure = model.failure { presentFailure(failure) }
        }
    }

    private var profileForm: some View {
        @Bindable var model = model
        return Form {
            avatarSection
                .disabled(model.isResetPending)
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
                .disabled(model.isResetPending)
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
                .disabled(model.isResetPending)
                .wnInputRow()
            } header: {
                Text("About").wnSectionHeader()
            }

            if let failureMessage = setupSaveError {
                Section {
                    Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
    }

    private var profileActions: some View {
        VStack(spacing: 8) {
            WNButton(
                title: LocalizedStringKey(primaryActionTitle),
                isLoading: isSaving || model.isSubmitting
            ) {
                submitProfile()
            }
            .disabled(isBusy || (!hasValidName && !model.isResetPending) || (accountSetup != nil && accountSetup?.isConnected != true))
            .accessibilityLabel(primaryActionTitle)
            .accessibilityIdentifier(accountSetup == nil ? "sign-up.create" : "account-setup.save-profile")
            .accessibilityValue(isSaving || model.isSubmitting ? "In progress" : "")
        }
    }

    private func saveDraftChanges() {
        guard isFormReady, accountSetup == nil else { return }
        Task { await model.persistDraft() }
    }

    private func presentFailure(_ failure: CreateIdentityViewModel.Failure) {
        if failure == .restart {
            if !isRestarting {
                restartError = failure.message
                confirmsStartOver = true
            }
        } else {
            signUpFailure = failure
        }
    }

    private func restartSignUp() {
        guard !isBusy else { return }
        confirmsStartOver = false
        isRestarting = true
        nameFocused = false; aboutFocused = false
        submissionTask = Task {
            defer { isRestarting = false }
            if await model.startOver(using: appState) {
                await model.prepare(using: appState)
                confirmsStartOver = false
                restartError = nil
            } else if !Task.isCancelled, !model.isRestorationBlocked, let failure = model.failure {
                restartError = failure.message
                confirmsStartOver = true
            }
        }
    }

    private func submitProfile() {
        if model.isResetPending {
            restartError = model.failure?.message
            confirmsStartOver = true
            return
        }
        nameFocused = false; aboutFocused = false
        submissionTask = Task {
            if let accountSetup {
                await saveImportedProfile(using: accountSetup)
            } else {
                await model.submit(using: appState, dismiss: { dismiss() })
                guard !Task.isCancelled, !model.isRestorationBlocked, let failure = model.failure else { return }
                presentFailure(failure)
            }
        }
    }

    private var avatarSection: some View {
        VStack(spacing: 0) {
            WNAvatarPhotoMenu(
                hasPhoto: model.avatarDraft != nil,
                isPresented: $showPhotoMenu
            ) {
                WNAvatarPreview(
                    name: model.displayName,
                    image: model.avatarDraft?.thumbnail,
                    pictureURL: ContentSanitizer.imageURL(accountSetup?.snapshot.proposal?.profile?.picture)
                )
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
        if model.isResetPending { return L10n.string("Start over") }
        if model.phase == .finishingSetup { return L10n.string("Finishing setup…") }
        if model.phase == .savingProfile { return L10n.string("Saving…") }
        if model.isSubmitting { return L10n.string("Signing Up…") }
        return L10n.string("Sign Up")
    }

    private var hasValidName: Bool {
        ContentSanitizer.displayName(model.displayName) != nil
    }

}

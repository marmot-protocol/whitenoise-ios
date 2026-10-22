import MarmotKit
import SwiftUI

struct CreateIdentityView: View {
    var isPushed = false
    var onCompletion: (() -> Void)?

    var body: some View {
        IdentityProfileSetupView(isPushed: isPushed, onCompletion: onCompletion)
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
    @State private var photoMenuAction: WNPhotoMenuAction?
    @State private var confirmsStartOver = false
    @State private var confirmsDiscardDraft = false
    @State private var discardDraftFailed = false
    @State private var isRestarting = false
    @State private var restartError: String?
    @State private var signUpFailure: CreateIdentityViewModel.Failure?
    @State private var failurePresentation = SignUpFailurePresentation()
    @State private var photoRemovalFailure: PhotoSelectionFailure?
    @State private var showPrivacyDetails = false
    @FocusState private var focusedField: WNProfileField?
    @State private var nameFieldHeight: CGFloat = 0
    @State private var aboutFieldHeight: CGFloat = 0

    let isPushed: Bool
    let accountSetup: AccountSetupModel?
    let onCompletion: (() -> Void)?
    @State private var profileFailure: AccountSetupProfilePresentation.Failure?
    @State private var profileExit: ProfileExit?
    @State private var activeProfileSnapshot: OnboardingSnapshotFfi?
    @State private var activeProfileAction: AccountSetupProfilePresentation.Action?
    @State private var profileActionCompleted = false
    @State private var pendingProfileDiscard: AccountSetupProfilePresentation.PendingDiscard?

    private enum ProfileExit { case close, skip, cancelRepair }

    private var recovery: AccountSetupProfilePresentation? {
        accountSetup.map { AccountSetupProfilePresentation(snapshot: activeProfileSnapshot ?? $0.snapshot) }
    }

    private var showsProfileFields: Bool {
        recovery?.canEdit ?? true
    }

    private var hasProfileChanges: Bool {
        guard accountSetup != nil, showsProfileFields else { return false }
        let profile = recovery?.profile
        return model.displayName != (profile?.displayName ?? profile?.name ?? "")
            || model.about != (profile?.about ?? "") || model.avatarDraft != nil
    }

    init(
        isPushed: Bool = false,
        accountSetup: AccountSetupModel? = nil,
        onCompletion: (() -> Void)? = nil
    ) {
        self.isPushed = isPushed
        self.accountSetup = accountSetup
        self.onCompletion = onCompletion
        _isFormReady = State(initialValue: accountSetup != nil)
    }

    private var importedProfileStatus: OnboardingStatusFfi? {
        accountSetup?.snapshot.steps.first { $0.step == .profile }?.status
    }

    private var isSetupConnectionBlocked: Bool {
        accountSetup?.hasConnectionFailure ?? false
    }

    private var didCompleteProfileDiscard: Bool {
        guard scenePhase == .active, let setup = accountSetup, setup.isConnected, !setup.isBusy else { return false }
        return pendingProfileDiscard?.isComplete(in: setup.snapshot) ?? false
    }

    private var profileFailureMessage: String? { profileFailure?.message }

    private var shouldDismissProfile: Bool {
        guard let setup = accountSetup, scenePhase == .active, setup.isConnected,
              activeProfileSnapshot == nil else { return false }
        return profileActionCompleted || importedProfileStatus == .passed || importedProfileStatus == .skipped
            || didCompleteProfileDiscard
    }

    private var hasFooterActions: Bool {
        guard !isSetupConnectionBlocked, let recovery else { return true }
        return recovery.primaryAction(failure: profileFailure) != nil || recovery.canSkip
    }

    private var showsRepairBack: Bool {
        !isSetupConnectionBlocked && recovery?.canCancelRepair == true
    }

    private var showsInlineActions: Bool {
        !isSetupConnectionBlocked && (accountSetup == nil || showsProfileFields)
    }

    private var isSaving: Bool { model.isSavingProfile || activeProfileSnapshot != nil || (accountSetup?.isBusy ?? false) }
    private var isBusy: Bool { isRestarting || model.isBusy || isSaving }
    private var allowsBackNavigation: Bool {
        !isRestarting && (accountSetup == nil ? model.allowsBackNavigation : !isSaving)
    }

    private var profileEditor: some View {
        WNProfileFormContainer(
            focusedField: focusedField, nameFieldHeight: nameFieldHeight, aboutFieldHeight: aboutFieldHeight
        ) {
            profileForm
        }
        .disabled(isBusy || isSaving)
        .wnPhotoSourceMenu(
            selection: $photoMenuAction,
            confirmsPublicUpload: false,
            prepareDraft: { data, fileName, sourceURL in
                try await ProfileImageDraftProcessor.prepare(
                    data: data,
                    fileName: fileName,
                    typeIdentifier: AvatarImageCropper.outputTypeIdentifier,
                    sourceURL: sourceURL
                )
            },
            onRemove: removePhoto,
            onSelect: { selection in
                try await model.acceptPreparedAvatar(selection)
                profileDraftDidChange()
            }
        )
    }

    private var presentedEditor: some View {
        Group {
            if isFormReady, model.isRestorationBlocked {
                restorationFailureView
            } else if isSetupConnectionBlocked {
                Form {
                    Section {
                        AccountSetupProfileError(
                            title: "Couldn’t continue signing in",
                            message: L10n.string("We couldn’t finish checking your sign-in. Go back to Sign In to try again.")
                        )
                        .padding(.vertical, 4)
                        .listRowBackground(Color(uiColor: .quaternarySystemFill))
                        .wnGroupedCardRow(.only)
                    }
                }
                .formStyle(.grouped)
                .contentMargins(.horizontal, 16, for: .scrollContent)
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
            presentNewFailure()
        }
        .photoSelectionFailureAlert(
            $photoRemovalFailure, title: "Couldn’t remove photo",
            message: CreateIdentityViewModel.Failure.draftStorage.message,
            retry: removePhoto, chooseAnother: nil
        )
        .wnProfileFailureAlert(
            $signUpFailure,
            title: signUpFailure == .photoUpload ? L10n.string("Couldn’t upload photo") : L10n.string("Couldn’t finish sign-up"),
            dismissTitle: { $0 == .photoUpload ? L10n.string("Cancel") : L10n.string("Close") },
            message: { $0.message },
            retry: { _ in submitProfile() }
        )
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
        profileContent
        .onDisappear {
            submissionTask?.cancel()
            flushDraftChanges()
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background {
                submissionTask?.cancel()
                flushDraftChanges()
            }
        }
        .onChange(of: shouldDismissProfile) {
            if shouldDismissProfile { dismiss() }
        }
        .task(id: accountSetup == nil ? scenePhase : .active) {
            await prepareForm()
        }
        .background {
            Color(uiColor: accountSetup == nil ? .systemBackground : .systemGroupedBackground)
                .ignoresSafeArea()
        }
    }

    private var profileContent: some View {
        profileNavigation
        .interactiveDismissDisabled(!isFormReady || !allowsBackNavigation || hasProfileChanges)
        .alert("Discard profile changes?", isPresented: Binding(
            get: { profileExit != nil },
            set: { if !$0 { profileExit = nil } }
        ), presenting: profileExit) { exit in
            Button("Discard changes", role: .destructive) {
                performProfileExit(exit)
                profileExit = nil
            }
            Button("Cancel", role: .cancel) { profileExit = nil }
        } message: { _ in
            Text("Your profile changes will be discarded.")
        }
        .modifier(WNOnboardingActionBar(
            isPresented: isFormReady && !model.isRestorationBlocked && !showsInlineActions && hasFooterActions
        ) {
            profileActions
                .safeAreaPadding(.horizontal, 16)
                .safeAreaPadding(.bottom)
        })
    }

    private var profileNavigation: some View {
        presentedEditor
        .onChange(of: model.displayName) { saveDraftChanges() }
        .onChange(of: model.about) { saveDraftChanges() }
        .onChange(of: isSetupConnectionBlocked) {
            if isSetupConnectionBlocked { focusedField = nil }
        }
        .sheet(isPresented: $showPrivacyDetails) {
            WNProfilePrivacyDetailsView()
                .presentationDetents(accountSetup == nil ? [.medium] : [.large])
                .presentationDragIndicator(accountSetup == nil ? .visible : .hidden)
                .presentationContentInteraction(.scrolls)
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(accountSetup == nil ? "Sign Up" : "Your profile")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar { profileToolbar }
    }

    @ToolbarContentBuilder private var profileToolbar: some ToolbarContent {
        if isFormReady {
            ToolbarItem(placement: .cancellationAction) {
                WNIconButton(
                    title: isPushed || showsRepairBack ? "Back" : "Close",
                    systemImage: isPushed || showsRepairBack ? "chevron.backward" : "xmark",
                    chrome: .container
                ) {
                    if accountSetup == nil {
                        appState.closeSignUpDraft()
                        dismiss()
                    } else {
                        requestProfileExit(showsRepairBack ? .cancelRepair : .close)
                    }
                }
                .disabled(!allowsBackNavigation)
                .allowsHitTesting(allowsBackNavigation)
            }
        }
        if isFormReady, accountSetup == nil, model.draft.requiresRecovery, !isBusy, !model.isResetPending, !model.isRestorationBlocked {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Start over", role: .destructive) {
                        focusedField = nil
                        restartError = nil
                        confirmsStartOver = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
    }

    private func prepareForm() async {
        guard accountSetup != nil || scenePhase == .active else { return }
        if let profile = accountSetup?.snapshot.proposal?.profile {
            model.displayName = profile.displayName ?? profile.name ?? ""
            model.about = profile.about ?? ""
        } else if accountSetup == nil {
            failurePresentation = SignUpFailurePresentation(
                retaining: appState.signUpModel.isFinished ? nil : appState.signUpModel.failure
            )
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
            presentNewFailure()
        }
    }

    private func presentNewFailure() {
        guard isFormReady, !model.isRestorationBlocked,
              let failure = failurePresentation.takeNewFailure(model.failure) else { return }
        presentFailure(failure)
    }

    private var profileForm: some View {
        @Bindable var model = model
        return Form {
            if let recovery {
                Section {
                    AccountSetupProfileStatus(
                        presentation: recovery, failureMessage: profileFailureMessage,
                        failedAction: profileFailure?.action, isBusy: isSaving, activeAction: activeProfileAction
                    ) {
                        if recovery.canEdit || recovery.profile != nil {
                            Divider()
                            privacyText
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color(uiColor: .quaternarySystemFill))
                    .wnGroupedCardRow(.only)
                }
            }

            if showsProfileFields {
                avatarSection
                    .disabled(model.isResetPending)

                WNProfileNameSection(text: $model.displayName, focus: $focusedField) {
                    nameFieldHeight = $0
                }
                .disabled(model.isResetPending)

                WNProfileAboutSection(text: $model.about, focus: $focusedField) {
                    aboutFieldHeight = $0
                }
                .disabled(model.isResetPending)
            } else if let profile = recovery?.profile {
                Section {
                    AccountSetupProfileSummary(profile: profile)
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            if accountSetup == nil {
                WNProfilePrivacySection(onLearnMore: openPrivacyDetails)
            }

            if showsInlineActions {
                Section {
                    profileActions
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .scrollIndicatorsFlash(onAppear: true)
    }

    private var privacyText: some View {
        WNProfilePrivacyNote(showsIcon: false, onLearnMore: openPrivacyDetails)
    }

    private func openPrivacyDetails() {
        focusedField = nil
        showPrivacyDetails = true
    }

    @ViewBuilder private var profileActions: some View {
        if isSetupConnectionBlocked {
            WNOnboardingButton(title: "Back to Sign In") { requestProfileExit(.close) }
                .disabled(!allowsBackNavigation)
        } else if let accountSetup, let recovery {
            recoveryActions(accountSetup, presentation: recovery)
        } else {
            signUpActions
        }
    }

    private var signUpActions: some View {
        VStack(spacing: 8) {
            WNOnboardingButton(
                title: LocalizedStringKey(primaryActionTitle),
                layoutTitle: "Sign Up",
                isLoading: isSaving || model.isSubmitting
            ) {
                submitProfile()
            }
            .disabled(isBusy || (!hasValidName && !model.isResetPending))
            .accessibilityLabel(primaryActionTitle)
            .accessibilityIdentifier("sign-up.create")
        }
    }

    private func requestProfileExit(_ exit: ProfileExit) {
        focusedField = nil
        if hasProfileChanges || exit == .cancelRepair { profileExit = exit }
        else { performProfileExit(exit) }
    }

    private func performProfileExit(_ exit: ProfileExit) {
        switch exit {
        case .close: dismiss()
        case .skip: performProfileAction(.skip)
        case .cancelRepair: performProfileAction(.cancelRepair)
        }
    }

    private func performProfileAction(_ action: AccountSetupProfilePresentation.Action) {
        guard let setup = accountSetup else { return }
        let command: AccountSetupCommand
        switch action {
        case .retry: command = .retry(.profile)
        case .skip: command = .skip(.profile)
        case .cancelRepair: command = .cancelRepair
        case .save: return
        }
        let discard = action == .cancelRepair ? AccountSetupProfilePresentation.PendingDiscard(snapshot: setup.snapshot) : nil
        let startingSnapshot = setup.snapshot
        guard let operation = setup.send(command) else { return }
        activeProfileSnapshot = startingSnapshot
        activeProfileAction = action
        profileFailure = nil
        pendingProfileDiscard = discard
        submissionTask = Task {
            defer {
                activeProfileSnapshot = nil
                activeProfileAction = nil
            }
            await operation.value
            guard !Task.isCancelled, setup.isConnected else { return }
            pendingProfileDiscard = nil
            if AccountSetupProfilePresentation.shouldDismiss(after: action, snapshot: setup.snapshot, errorMessage: setup.errorMessage) {
                profileFailure = nil
                profileActionCompleted = true
            } else {
                profileFailure = setup.errorMessage.map { .init(action: action, message: $0) }
            }
        }
    }

    private func recoveryActions(_ setup: AccountSetupModel, presentation: AccountSetupProfilePresentation) -> some View {
        VStack(spacing: 8) {
            if let primary = presentation.primaryAction(failure: profileFailure) {
                WNOnboardingButton(
                    title: primary.isRetry ? "Try Again" : "Save",
                    isLoading: isSaving && activeProfileAction != .skip && activeProfileAction != .cancelRepair
                ) {
                    if primary.action == .save { submitProfile() }
                    else { performProfileAction(.retry) }
                }
                .disabled(isBusy || !setup.isConnected || (primary.action == .save && !hasValidName))
                .accessibilityIdentifier(primary.isRetry ? "account-setup.retry-profile" : "account-setup.save-profile")
            }
            if presentation.canSkip {
                WNButton(title: "Not Now", emphasis: .secondary) { requestProfileExit(.skip) }
                    .disabled(isBusy || !setup.isConnected)
            }
        }
    }

    private func removePhoto() {
        guard !isBusy else { return }
        photoRemovalFailure = nil
        submissionTask = Task {
            do {
                try await model.acceptPreparedAvatar(nil)
                profileDraftDidChange()
            } catch is CancellationError {
                return
            } catch {
                photoRemovalFailure = PhotoSelectionFailure.classify(error, fallback: .storage)
            }
        }
    }

    private func profileDraftDidChange() {
        pendingProfileDiscard = nil
        if profileFailure?.action == .save { profileFailure?.draftWasEdited = true }
    }

    private func saveDraftChanges() {
        profileDraftDidChange()
        guard isFormReady, accountSetup == nil else { return }
        model.scheduleDraftPersistence()
    }

    private func flushDraftChanges() {
        guard accountSetup == nil else { return }
        let draftModel = model
        Task { await draftModel.persistDraft() }
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
        focusedField = nil
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
        focusedField = nil
        submissionTask = Task {
            if let accountSetup {
                await saveImportedProfile(using: accountSetup)
            } else {
                await model.submit(using: appState, dismiss: {
                    if let onCompletion { onCompletion() } else { dismiss() }
                })
                guard !Task.isCancelled, !model.isRestorationBlocked, let failure = model.failure else { return }
                presentFailure(failure)
            }
        }
    }

    private var avatarSection: some View {
        WNProfilePhotoSection(hasPhoto: model.avatarDraft != nil, selection: $photoMenuAction) {
            WNAvatarPreview(
                name: model.displayName,
                image: model.avatarDraft?.thumbnail,
                pictureURL: ContentSanitizer.imageURL(accountSetup?.snapshot.proposal?.profile?.picture)
            )
        }
    }

    private func saveImportedProfile(using setup: AccountSetupModel) async {
        pendingProfileDiscard = nil
        let draft = OnboardingProfileMetadataDraft(
            displayName: model.displayName, about: model.about, uploadedPictureURL: nil
        )
        guard let profile = draft.merging(with: setup.snapshot.proposal?.profile) else { return }
        let avatar = model.avatarDraft.map { AccountSetupAvatar(data: $0.data, mediaType: $0.mediaType) }
        activeProfileSnapshot = setup.snapshot
        activeProfileAction = .save
        profileFailure = nil
        defer {
            activeProfileSnapshot = nil
            activeProfileAction = nil
        }
        let saved = await setup.saveProfile(profile, avatar: avatar)
        guard !Task.isCancelled, setup.isConnected else { return }
        if saved {
            Haptics.success()
            profileActionCompleted = true
        } else if let message = setup.errorMessage {
            profileFailure = .init(action: .save, message: message)
            Haptics.error()
        }
    }

    private var primaryActionTitle: String {
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

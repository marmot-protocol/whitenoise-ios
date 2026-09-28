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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum ProfileField: Hashable {
        case name
        case about
    }

    @State private var model = CreateIdentityViewModel()
    @State private var showPhotoMenu = false
    @State private var isKeyboardVisible = false
    @State private var showPrivacyDetails = false
    @FocusState private var focusedField: ProfileField?
    @State private var nameFieldHeight: CGFloat = 0
    @State private var aboutFieldHeight: CGFloat = 0

    let isPushed: Bool
    let accountSetup: AccountSetupModel?
    @State private var setupSaveError: String?
    @State private var hasSubmittedProfile = false

    init(isPushed: Bool = false, accountSetup: AccountSetupModel? = nil) {
        self.isPushed = isPushed
        self.accountSetup = accountSetup
    }

    private var showsInlineActions: Bool { accountSetup == nil && isKeyboardVisible }

    private var isSaving: Bool { model.isSavingProfile || (accountSetup?.isBusy ?? false) }
    private var isBusy: Bool { model.isBusy || (accountSetup?.isBusy ?? false) }
    private var allowsBackNavigation: Bool {
        accountSetup == nil ? model.allowsBackNavigation : !isSaving
    }

    var body: some View {
        ScrollViewReader { proxy in
            profileForm
                .onChange(of: focusedField) {
                    revealFocusedField(using: proxy)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                    revealFocusedField(using: proxy)
                }
                .onScrollGeometryChange(for: CGSize.self) { geometry in
                    geometry.visibleRect.size
                } action: { oldSize, newSize in
                    // Follow keyboard avoidance, without fighting interactive keyboard dismissal.
                    if newSize.height < oldSize.height || newSize.width != oldSize.width {
                        revealFocusedField(using: proxy)
                    }
                }
                .onChange(of: nameFieldHeight) {
                    if focusedField == .name { revealFocusedField(using: proxy) }
                }
                .onChange(of: aboutFieldHeight) {
                    if focusedField == .about { revealFocusedField(using: proxy) }
                }
        }
        .disabled(isSaving || accountSetup?.isResumingProfilePublication == true)
        .formStyle(.grouped)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .wnPhotoSourceMenu(
            isPresented: $showPhotoMenu,
            hasPhoto: model.avatarDraft != nil,
            confirmsPublicUpload: false,
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
        .sheet(isPresented: $showPrivacyDetails) {
            ProfilePrivacyDetailsView()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
        }
        .scrollContentBackground(.hidden)
        .compatibleBottomScrollEdgeEffectHidden()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(accountSetup == nil ? "Sign Up" : "Update profile")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            if allowsBackNavigation {
                ToolbarItem(placement: .cancellationAction) {
                    WNIconButton(
                        title: isPushed ? "Back" : "Close",
                        systemImage: isPushed ? "chevron.backward" : "xmark",
                        chrome: .container
                    ) {
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(!allowsBackNavigation)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !showsInlineActions {
                profileActions
                    .safeAreaPadding(.horizontal, 16)
                    .safeAreaPadding(.bottom)
            }
        }
        // Native keyboard avoidance owns the motion; animating Form updates also morphs its rows.
        .trackKeyboardVisibility($isKeyboardVisible, animatesChanges: false)
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
        .background {
            Color(.systemBackground)
                .ignoresSafeArea()
        }
    }

    private var profileForm: some View {
        @Bindable var model = model

        return Form {
            avatarSection
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            Section("Name") {
                TextField("Name", text: $model.displayName)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .name)
                    .onSubmit { focusedField = .about }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { nameFieldHeight = $0 }
                    .id(ProfileField.name)
                    .listRowBackground(Color(uiColor: .secondarySystemFill))
            }

            Section {
                TextField("A little about you", text: $model.about, axis: .vertical)
                    .lineLimit(3 ... 6)
                    .textInputAutocapitalization(.sentences)
                    .focused($focusedField, equals: .about)
                    .accessibilityLabel("About")
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { aboutFieldHeight = $0 }
                    .id(ProfileField.about)
                    .listRowBackground(Color(uiColor: .secondarySystemFill))
            } header: {
                Text("About")
            }

            Section {
                privacyNote
                    .padding(.vertical, 4)
                    .listRowBackground(Color(uiColor: .quaternarySystemFill))
            }

            if let failureMessage = setupSaveError ?? model.failureMessage {
                Section {
                    Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
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
        .safeAreaPadding(.bottom, isKeyboardVisible ? BottomInputChromeLayout.keyboardInset : 0)
    }

    private func revealFocusedField(using proxy: ScrollViewProxy) {
        guard let focusedField else { return }
        withAnimation(reduceMotion ? nil : .default) {
            // A nil anchor reveals the whole row with the smallest possible scroll.
            proxy.scrollTo(focusedField)
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "eye")
                .accessibilityHidden(true)
            Text(privacySummary)
                .fixedSize(horizontal: false, vertical: true)
                .tint(.primary)
                .environment(\.openURL, OpenURLAction { _ in
                    focusedField = nil
                    showPrivacyDetails = true
                    return .handled
                })
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var privacySummary: AttributedString {
        var summary = AttributedString(L10n.string("Your name, photo, and bio are public.\nShare only what you’re comfortable with."))
        var learnMore = AttributedString(L10n.string("Learn more"))
        learnMore.link = URL(string: "whitenoise:profile-privacy")
        learnMore.underlineStyle = .single
        summary += AttributedString("\n")
        summary += learnMore
        return summary
    }

    private var profileActions: some View {
        VStack(spacing: 8) {
            WNOnboardingButton(
                title: LocalizedStringKey(primaryActionTitle),
                layoutTitle: accountSetup == nil ? "Sign Up" : "Save",
                isLoading: isSaving || model.isSubmitting
            ) {
                focusedField = nil
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

}

private struct ProfilePrivacyDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .title) private var iconSize = 48.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "eye")
                    .font(.system(size: iconSize))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Your profile is public")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Your name, photo, and bio are visible to everyone. Use a nickname and share only what you’re comfortable making public.")
                Text("Photos may stay online even after you remove them from your profile.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer()
                WNIconButton(title: "Close", systemImage: "xmark") {
                    dismiss()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
        .font(.body)
        .foregroundStyle(.primary)
        .presentationBackground(Color(uiColor: .systemBackground))
    }
}

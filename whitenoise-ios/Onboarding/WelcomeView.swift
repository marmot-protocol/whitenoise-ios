import SwiftUI

/// First-launch and add-profile entry point. First launch presents bounded
/// sheets; Add Profile pushes into the sheet's existing navigation stack.
struct WelcomeView: View {
    private struct ConsentRuntimeState: Equatable {
        let generation: Int
        let isReady: Bool
    }

    private enum SheetRoute: Identifiable {
        case diagnostics
        case signIn
        case signUp

        var id: Self { self }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var sheetRoute: SheetRoute?
    @State private var showSignIn = false
    @State private var showSignUp = false
    @State private var selectedSheetDetent = PresentationDetent.large

    let isAddingProfile: Bool
    let onSheetContentChange: (OnboardingSheetContent) -> Void
    let onSignInExpansionChange: (Bool) -> Void

    init(
        isAddingProfile: Bool = false,
        onSheetContentChange: @escaping (OnboardingSheetContent) -> Void = { _ in },
        onSignInExpansionChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.isAddingProfile = isAddingProfile
        self.onSheetContentChange = onSheetContentChange
        self.onSignInExpansionChange = onSignInExpansionChange
    }

    private var accentColor: Color {
        colorScheme == .dark ? .white : .black
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image("WhiteNoiseMark")
                .resizable()
                .scaledToFit()
                .containerRelativeFrame(.horizontal, count: 2, span: 1, spacing: 0)
                .accessibilityLabel("White Noise")

            Spacer()

            VStack {
                if !isAddingProfile, let error = appState.diagnosticsConsent.errorMessage {
                    Text(error).font(.footnote)
                    Button("Retry") { Task { await appState.diagnosticsConsent.reload(using: appState); presentConsentIfNeeded() } }
                }
                WNButton(title: "Sign Up") {
                    open(.signUp)
                }
                .accessibilityIdentifier("welcome.sign-up")
                .disabled(!isAddingProfile && !appState.diagnosticsConsent.initialDecisionResolved)

                WNButton(title: "Sign In", emphasis: .secondary) {
                    open(.signIn)
                }
                .accessibilityIdentifier("welcome.sign-in")
                .disabled(!isAddingProfile && !appState.diagnosticsConsent.initialDecisionResolved)
            }
        }
        .safeAreaPadding(.horizontal)
        .safeAreaPadding(.bottom)
        .background {
            Color(.systemBackground)
                .ignoresSafeArea()
        }
        .tint(accentColor)
        .navigationDestination(isPresented: $showSignIn) {
            ImportIdentityView(
                onPreferredSheetExpansionChange: updateSignInExpansion
            )
        }
        .navigationDestination(isPresented: $showSignUp) {
            CreateIdentityView()
        }
        .sheet(item: $sheetRoute, onDismiss: {
            appState.diagnosticsConsent.onboardingVisible = false
            appState.cancelProductOnboardingIfAbandoned()
        }) { route in
            NavigationStack {
                switch route {
                case .diagnostics:
                    DiagnosticsAndImprovementsView(isPrompt: true)
                case .signIn:
                    ImportIdentityView(
                        showsCloseButton: true,
                        onPreferredSheetExpansionChange: updateSignInExpansion
                    )
                case .signUp:
                    CreateIdentityView(showsCloseButton: true)
                }
            }
            .tint(accentColor)
            .onAppear { appState.diagnosticsConsent.onboardingVisible = route != .diagnostics }
            .onDisappear { appState.diagnosticsConsent.onboardingVisible = false }
            .appAppearance()
            .presentationDetents(
                route != .signUp && !dynamicTypeSize.isAccessibilitySize ? [.medium, .large] : [.large],
                selection: $selectedSheetDetent
            )
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.resizes)
        }
        .task(id: ConsentRuntimeState(generation: appState.runtimeGeneration, isReady: appState.canUseRuntimeForLocalForegroundWork)) {
            guard !isAddingProfile else { return }
            await appState.diagnosticsConsent.reload(using: appState)
            presentConsentIfNeeded()
        }
        .onChange(of: appState.diagnosticsConsent.pending) { presentConsentIfNeeded() }
        .productScreen(.onboarding)
        .onChange(of: showSignIn) {
            if !showSignIn {
                appState.cancelProductOnboardingIfAbandoned()
                onSheetContentChange(.welcome)
                onSignInExpansionChange(false)
            }
        }
        .onChange(of: showSignUp) {
            if !showSignUp {
                appState.cancelProductOnboardingIfAbandoned()
                onSheetContentChange(.welcome)
            }
        }
    }

    private func presentConsentIfNeeded() {
        guard !isAddingProfile, sheetRoute == nil,
              appState.canUseRuntimeForLocalForegroundWork,
              appState.diagnosticsConsent.pending,
              !appState.erasureState.needsRecovery, appState.pendingWipeReport == nil else { return }
        selectedSheetDetent = .medium
        sheetRoute = .diagnostics
    }

    private func open(_ route: SheetRoute) {
        guard isAddingProfile || appState.diagnosticsConsent.initialDecisionResolved else {
            presentConsentIfNeeded()
            return
        }
        let path: ProductOnboardingPath = route == .signIn ? .import : .create
        appState.beginProductOnboarding(path)
        selectedSheetDetent = route == .signIn ? .medium : .large
        if !isAddingProfile {
            sheetRoute = route
        } else {
            switch route {
            case .diagnostics: break
            case .signIn:
                onSheetContentChange(.signIn)
                onSignInExpansionChange(false)
                showSignIn = true
            case .signUp:
                onSheetContentChange(.signUp)
                showSignUp = true
            }
        }
    }

    private func updateSignInExpansion(_ isExpanded: Bool) {
        selectedSheetDetent = isExpanded ? .large : .medium
        onSignInExpansionChange(isExpanded)
    }
}

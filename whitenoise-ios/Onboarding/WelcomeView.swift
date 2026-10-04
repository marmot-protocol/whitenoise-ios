import SwiftUI

nonisolated struct WelcomeBrandBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// First-launch and add-profile entry point. First launch presents bounded
/// sheets; Add Profile pushes into the sheet's existing navigation stack.
struct WelcomeView: View {
    private enum SheetRoute: Identifiable {
        case signIn
        case signUp

        var id: Self { self }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

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

    private var actionLayout: AnyLayout {
        verticalSizeClass == .compact ? AnyLayout(HStackLayout()) : AnyLayout(VStackLayout())
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Image("WhiteNoiseMark")
                        .resizable()
                        .scaledToFit()
                        .containerRelativeFrame(.horizontal, count: 2, span: 1, spacing: 0)
                        .frame(maxHeight: geometry.size.height * 0.3)
                        .accessibilityLabel("White Noise")
                        .anchorPreference(key: WelcomeBrandBoundsKey.self, value: .bounds) { $0 }
                    Spacer(minLength: 0)

                    VStack {
                        actionLayout {
                            WNButton(title: "Sign In", emphasis: .secondary) { open(.signIn) }
                                .accessibilityIdentifier("welcome.sign-in")
                            WNButton(title: "Sign Up") { open(.signUp) }
                                .accessibilityIdentifier("welcome.sign-up")
                        }
                        Text("By signing up or signing in, you agree to our [Terms of Service](https://whitenoise.chat/terms).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("welcome.terms")
                    }
                }
                .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaPadding(.horizontal)
        .safeAreaPadding(.bottom)
        .background(.background)
        .tint(accentColor)
        .navigationDestination(isPresented: $showSignIn) {
            ImportIdentityView(
                isPushed: true,
                onPreferredSheetExpansionChange: updateSignInExpansion
            )
        }
        .navigationDestination(isPresented: $showSignUp) {
            CreateIdentityView(isPushed: true)
        }
        .sheet(item: $sheetRoute, onDismiss: {
            appState.cancelProductOnboardingIfAbandoned()
        }) { route in
            NavigationStack {
                switch route {
                case .signIn:
                    ImportIdentityView(
                        onPreferredSheetExpansionChange: updateSignInExpansion
                    )
                case .signUp:
                    CreateIdentityView()
                }
            }
            .tint(accentColor)
            .appAppearance()
            .presentationDetents(
                route != .signUp && !dynamicTypeSize.isAccessibilitySize ? [.medium, .large] : [.large],
                selection: $selectedSheetDetent
            )
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.resizes)
        }
        #if DEBUG
        .modifier(AccountRecoveryScenarioLauncher())
        #endif
        .productScreen(.onboarding)
        .onChange(of: showSignIn) {
            if !showSignIn {
                appState.cancelProductOnboardingIfAbandoned()
                onSheetContentChange(.welcome)
                onSignInExpansionChange(false)
            }
        }
        .onChange(of: sheetRoute) { previous, current in
            if previous == .signUp && current == nil {
                appState.closeSignUpDraft()
            }
        }
        .onChange(of: showSignUp) {
            if !showSignUp {
                appState.closeSignUpDraft()
                appState.cancelProductOnboardingIfAbandoned()
                onSheetContentChange(.welcome)
            }
        }
    }

    private func open(_ route: SheetRoute) {
        let path: ProductOnboardingPath = route == .signIn ? .import : .create
        appState.beginProductOnboarding(path)
        selectedSheetDetent = route == .signIn ? .medium : .large
        if !isAddingProfile {
            sheetRoute = route
        } else {
            switch route {
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

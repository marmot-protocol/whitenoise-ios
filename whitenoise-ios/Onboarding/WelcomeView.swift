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
    // Shared by profiles on this installation; Erase App Data clears app defaults.
    @AppStorage("welcome.hasAcceptedTerms") private var hasAcceptedTerms = false

    let isAddingProfile: Bool
    let onSheetContentChange: (OnboardingSheetContent) -> Void
    let onSignInExpansionChange: (Bool) -> Void
    let onPresentSignIn: (() -> Void)?
    let onChatsOpened: () -> Void

    init(
        isAddingProfile: Bool = false,
        onSheetContentChange: @escaping (OnboardingSheetContent) -> Void = { _ in },
        onSignInExpansionChange: @escaping (Bool) -> Void = { _ in },
        onPresentSignIn: (() -> Void)? = nil,
        onChatsOpened: @escaping () -> Void = {}
    ) {
        self.isAddingProfile = isAddingProfile
        self.onSheetContentChange = onSheetContentChange
        self.onSignInExpansionChange = onSignInExpansionChange
        self.onPresentSignIn = onPresentSignIn
        self.onChatsOpened = onChatsOpened
    }

    private var accentColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var actionLayout: AnyLayout {
        verticalSizeClass == .compact ? AnyLayout(HStackLayout()) : AnyLayout(VStackLayout())
    }

    var body: some View {
        GeometryReader { geometry in
            // Match LaunchScreen's centered, half-width mark independently of the copy and actions.
            let fullHeight = geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
            let markHeight = min(geometry.size.width * 0.5 * (460.0 / 598.0), fullHeight * 0.3)
            let markTop = max(0, fullHeight / 2 - geometry.safeAreaInsets.top - markHeight / 2)

            ScrollView {
                VStack(spacing: 0) {
                    Image("WhiteNoiseMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: markHeight * (598.0 / 460.0), height: markHeight)
                        .accessibilityLabel("White Noise")
                        .anchorPreference(key: WelcomeBrandBoundsKey.self, value: .bounds) { $0 }
                        .padding(.top, markTop)

                    if !hasAcceptedTerms {
                        VStack(spacing: 8) {
                            Text("Welcome to White Noise")
                                .font(.title.bold())
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)

                            Text("By continuing, you agree to our [Terms of Service](https://whitenoise.chat/terms) and [Acceptable Use Policy](https://whitenoise.chat/terms#section-7).")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 16)
                                .accessibilityIdentifier("welcome.terms")
                        }
                        .padding(.top, 32)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                welcomeActions
                    .padding(.horizontal)
                    .padding(.bottom)
            }
        }
        .background(.background)
        .tint(accentColor)
        .navigationDestination(isPresented: $showSignIn) {
            ImportIdentityView(
                isPushed: true,
                onPreferredSheetExpansionChange: updateSignInExpansion,
                onChatsOpened: onChatsOpened
            )
        }
        .navigationDestination(isPresented: $showSignUp) {
            CreateIdentityView(isPushed: true, onCompletion: isAddingProfile ? onChatsOpened : nil)
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
            .presentationSizing(WelcomeSheetSizing(isSignUp: route == .signUp))
        }
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

    private var welcomeActions: some View {
        Group {
            if hasAcceptedTerms {
                actionLayout {
                    WNButton(title: "Sign In", emphasis: .secondary) { open(.signIn) }
                        .accessibilityIdentifier("welcome.sign-in")
                    WNButton(title: "Sign Up") { open(.signUp) }
                        .accessibilityIdentifier("welcome.sign-up")
                }
            } else {
                WNButton(title: "Agree & Continue") {
                    hasAcceptedTerms = true
                }
                .accessibilityIdentifier("welcome.agree-and-continue")
            }
        }
    }

    private func open(_ route: SheetRoute) {
        let path: ProductOnboardingPath = route == .signIn ? .import : .create
        appState.beginProductOnboarding(path)
        selectedSheetDetent = route == .signIn ? .medium : .large
        if !isAddingProfile {
            if route == .signIn, let onPresentSignIn {
                onPresentSignIn()
            } else {
                sheetRoute = route
            }
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

/// iPad form sheets are too short to show the whole sign-up form.
private struct WelcomeSheetSizing: PresentationSizing {
    let isSignUp: Bool

    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        isSignUp
            ? PagePresentationSizing.page.proposedSize(for: root, context: context)
            : FormPresentationSizing.form.proposedSize(for: root, context: context)
    }
}

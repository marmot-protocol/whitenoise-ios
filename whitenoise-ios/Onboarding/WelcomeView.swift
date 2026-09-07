import SwiftUI

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

    @State private var sheetRoute: SheetRoute?
    @State private var showSignIn = false
    @State private var showSignUp = false
    @State private var selectedSheetDetent = PresentationDetent.large

    let onSheetContentChange: (OnboardingSheetContent) -> Void
    let onSignInExpansionChange: (Bool) -> Void

    init(
        onSheetContentChange: @escaping (OnboardingSheetContent) -> Void = { _ in },
        onSignInExpansionChange: @escaping (Bool) -> Void = { _ in }
    ) {
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
                WNButton(title: "Sign Up") {
                    open(.signUp)
                }
                .accessibilityIdentifier("welcome.sign-up")

                WNButton(title: "Sign In", emphasis: .secondary) {
                    open(.signIn)
                }
                .accessibilityIdentifier("welcome.sign-in")
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
        .sheet(item: $sheetRoute) { route in
            NavigationStack {
                switch route {
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
            .appAppearance()
            .presentationDetents(
                route == .signIn ? [.medium, .large] : [.large],
                selection: $selectedSheetDetent
            )
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.resizes)
        }
        .onChange(of: showSignIn) {
            if !showSignIn {
                onSheetContentChange(.welcome)
                onSignInExpansionChange(false)
            }
        }
        .onChange(of: showSignUp) {
            if !showSignUp {
                onSheetContentChange(.welcome)
            }
        }
    }

    private func open(_ route: SheetRoute) {
        selectedSheetDetent = route == .signIn ? .medium : .large
        if appState.accounts.isEmpty {
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

import SwiftUI
import MarmotKit

nonisolated enum RootPresentation: Hashable {
    case bootstrap
    case onboarding
    case profileSelection
    case main
    case failed(String)

    static func resolve(phase: AppState.Phase, activeAccountRef: String?) -> RootPresentation {
        switch phase {
        case .bootstrapping:
            .bootstrap
        case .onboarding:
            .onboarding
        case .ready:
            activeAccountRef == nil ? .profileSelection : .main
        case .failed(let message):
            .failed(message)
        }
    }
}

/// Top-level router. Routes between the bootstrap splash, the onboarding
/// flow (when no accounts exist), and the main app once at least one
/// identity is set up.
struct RootView: View {
    private enum RootSheet: Hashable {
        case signIn, signUp, erasureRecovery
    }

    @Environment(AppState.self) private var appState
    @State private var showSignIn = false
    @State private var visibleRootSheets: Set<RootSheet> = []

    var body: some View {
        let presentation = RootPresentation.resolve(
            phase: appState.phase,
            activeAccountRef: appState.activeAccountRef
        )
        ZStack {
            rootContent(presentation)
                // Each root owns its navigation stack. Never carry a completed
                // deletion destination through the chooser into the next profile.
                .id(presentation)
                .animation(showSignIn ? nil : .smooth(duration: 0.25), value: presentation)
        }
        .toastHost()
        // Keep the presenter alive when Chats replaces Welcome behind the sheet.
        .sheet(isPresented: $showSignIn, onDismiss: {
            visibleRootSheets.remove(.signIn)
            appState.diagnosticsConsent.onboardingVisible = false
            appState.cancelProductOnboardingIfAbandoned()
        }) {
            InitialSignInSheet()
                .onAppear { visibleRootSheets.insert(.signIn) }
        }
        .onChange(of: presentation) { _, current in
            if current != .onboarding { showSignIn = false }
        }
        .sheet(isPresented: Binding(
            get: { appState.restoreSignUpPresentation && appState.phaseOwnsLiveRuntime },
            set: { presented in
                appState.restoreSignUpPresentation = presented
                if !presented { appState.closeSignUpDraft() }
            }
        ), onDismiss: {
            visibleRootSheets.remove(.signUp)
        }) {
            NavigationStack { CreateIdentityView() }
                .appAppearance()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationSizing(.page)
                .onAppear { visibleRootSheets.insert(.signUp) }
        }
        .task(id: appState.runtimeEventsGeneration) {
            await appState.observeRuntimeEvents()
        }
        .sheet(isPresented: Binding(
            get: { shouldPresentErasureRecovery },
            // Recovery state belongs to the erasure operation, not sheet dismissal.
            set: { _ in }
        ), onDismiss: {
            visibleRootSheets.remove(.erasureRecovery)
        }) {
            EraseAppDataView(isRecovery: true)
                .appAppearance()
                .onAppear { visibleRootSheets.insert(.erasureRecovery) }
        }
        // Results precede profile selection in the same presenter, so the
        // chooser cannot race either the sign-out sheet or cleanup reporting.
        .sheet(isPresented: Binding(
            get: { accountExitPresentation != nil },
            set: { presented in
                if !presented {
                    appState.accountExitIntent = nil
                    appState.pendingWipeReport = nil
                }
            }
        )) {
            if let report = appState.pendingWipeReport {
                WipeOutcomeReportView(report: report) {
                    appState.accountExitIntent = nil
                    appState.pendingWipeReport = nil
                }
                .appAppearance()
                // Close advances to the chooser without dismissing its presenter.
                .interactiveDismissDisabled(needsSettingsProfileSelection)
            } else if accountExitPresentation == .signOut {
                SignOutView(intent: .signOut)
                    .appAppearance()
            } else if accountExitPresentation == .profileSelection {
                AccountExitProfileChooser()
                    .appAppearance()
            }
        }
    }

    private var shouldPresentErasureRecovery: Bool {
        appState.erasureState.shouldPresentRecovery(
            activeAccountRef: appState.activeAccountRef,
            runtimeReady: appState.canUseRuntimeForLocalForegroundWork
        )
    }

    private var canPresentProfiles: Bool {
        // Keep the chooser deferred through other root sheets' dismissal animations.
        visibleRootSheets.isEmpty && !showSignIn
            && !(appState.restoreSignUpPresentation && appState.phaseOwnsLiveRuntime)
            && !shouldPresentErasureRecovery
    }

    private var needsSettingsProfileSelection: Bool {
        appState.phase == .ready
            && appState.activeAccountRef == nil
            && appState.accountStore.returnsToSettingsAfterSelection
    }

    private var accountExitPresentation: AccountExitPresentation? {
        let presentation = AccountExitPresentation.resolve(
            intent: appState.accountExitIntent,
            hasReport: appState.pendingWipeReport != nil,
            needsProfileSelection: needsSettingsProfileSelection,
            isExiting: appState.isAccountExitInProgress
        )
        if presentation == .profileSelection, !canPresentProfiles { return nil }
        return presentation
    }

    @ViewBuilder
    private func rootContent(_ presentation: RootPresentation) -> some View {
        switch presentation {
        case .bootstrap:
            BootstrapSplash()
        case .onboarding:
            NavigationStack {
                WelcomeView(onPresentSignIn: {
                    appState.diagnosticsConsent.onboardingVisible = true
                    showSignIn = true
                })
            }
        case .profileSelection:
            if needsSettingsProfileSelection {
                NavigationStack {
                    // No profile is active until the user explicitly chooses.
                    SettingsView(onAddProfile: {}, recordsScreenView: false)
                        .disabled(true)
                }
            } else {
                SignedOutProfilesView()
            }
        case .main:
            MainView()
        case .failed(let message):
            BootstrapFailureView(message: message)
        }
    }
}

private struct AccountExitProfileChooser: View {
    @Environment(AppState.self) private var appState
    @State private var showAddProfile = false

    var body: some View {
        NavigationStack {
            AccountsView(
                activeAccountRef: appState.activeAccountRef,
                signedInAccountCount: appState.accounts.filter { !$0.signedOut }.count,
                requiresSelection: true,
                onAddProfile: { showAddProfile = true }
            )
        }
        .sheet(isPresented: $showAddProfile) {
            AddProfileSheet()
        }
    }
}

private struct InitialSignInSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedDetent = PresentationDetent.medium

    var body: some View {
        NavigationStack {
            ImportIdentityView(onPreferredSheetExpansionChange: { expanded in
                selectedDetent = expanded ? .large : .medium
            })
        }
        .tint(colorScheme == .dark ? .white : .black)
        .appAppearance()
        .presentationDetents(
            dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large],
            selection: $selectedDetent
        )
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.resizes)
    }
}

private struct BootstrapSplash: View {
    var body: some View {
        LaunchBrandView()
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

private struct BootstrapFailureView: View {
    let message: String
    @Environment(AppState.self) private var appState

    var body: some View {
        ContentUnavailableView {
            Label("Startup failed", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } actions: {
            Button("Retry") {
                Task { await appState.bootstrap() }
            }
            .wnPrimaryButtonStyle()
            .controlSize(.large)
        }
        .padding()
    }
}

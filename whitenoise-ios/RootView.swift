import SwiftUI

nonisolated enum RootPresentation: Equatable {
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
    @Environment(AppState.self) private var appState

    var body: some View {
        let presentation = RootPresentation.resolve(
            phase: appState.phase,
            activeAccountRef: appState.activeAccountRef
        )
        // Reserve layout space so navigation content cannot overlap the resume action.
        VStack(spacing: 0) {
            rootContent(presentation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if appState.pendingAccountSetup != nil, !appState.isAccountSetupPresented {
                Button {
                    appState.isAccountSetupPresented = true
                } label: {
                    Text("Finish account setup")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .background(.background)
            }
        }
        .animation(.smooth(duration: 0.25), value: presentation)
        .toastHost()
        // Hosted at the root so a partial-failure wipe report survives the
        // account teardown (routing to onboarding / switching accounts pops the
        // Settings screen that started the wipe).
        .sheet(isPresented: Binding(
            get: { appState.pendingWipeReport != nil },
            set: { if !$0 { appState.pendingWipeReport = nil } }
        )) {
            if let report = appState.pendingWipeReport {
                WipeOutcomeReportView(report: report) {
                    appState.pendingWipeReport = nil
                }
                .appAppearance()
            }
        }
    }

    @ViewBuilder
    private func rootContent(_ presentation: RootPresentation) -> some View {
        if let setup = appState.pendingAccountSetup,
           appState.isAccountSetupPresented,
           appState.phaseOwnsLiveRuntime {
            NavigationStack {
                AccountSetupView(model: setup)
            }
            .id(setup.accountID)
            .task(id: "\(appState.runtimeGeneration):\(appState.canUseRuntimeForLocalForegroundWork)") {
                if appState.canUseRuntimeForLocalForegroundWork {
                    await appState.connectAccountSetup()
                } else {
                    setup.suspend()
                }
            }
            .onDisappear { setup.suspend() }
        } else {
            switch presentation {
            case .bootstrap:
                BootstrapSplash()
            case .onboarding:
                NavigationStack {
                    WelcomeView()
                }
            case .profileSelection:
                SignedOutProfilesView()
            case .main:
                MainView()
            case .failed(let message):
                BootstrapFailureView(message: message)
            }
        }
    }
}

private struct BootstrapSplash: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            Image("WnLogo")
                .accessibilityHidden(true)
        }
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
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

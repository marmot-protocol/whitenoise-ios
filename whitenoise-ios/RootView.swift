import SwiftUI
import MarmotKit

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
        rootContent(presentation)
        .animation(.smooth(duration: 0.25), value: presentation)
        .toastHost()
        .sheet(isPresented: Binding(
            get: { appState.erasureState.shouldPresentRecovery(
                activeAccountRef: appState.activeAccountRef,
                runtimeReady: appState.canUseRuntimeForLocalForegroundWork
            ) },
            set: { if !$0 { appState.erasureState.needsRecovery = false } }
        )) { EraseAppDataView(isRecovery: true).appAppearance() }
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

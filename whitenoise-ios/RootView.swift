import SwiftUI

/// Top-level router. Routes between the bootstrap splash, the onboarding
/// flow (when no accounts exist), and the main app once at least one
/// identity is set up.
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch appState.phase {
            case .bootstrapping:
                BootstrapSplash()
            case .onboarding:
                WelcomeView()
            case .ready:
                MainView()
            case .failed(let message):
                BootstrapFailureView(message: message)
            }
        }
        .animation(.smooth(duration: 0.25), value: appState.phase)
        .toastHost()
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

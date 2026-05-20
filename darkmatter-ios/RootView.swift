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
                MainTabView()
            case .failed(let message):
                BootstrapFailureView(message: message)
            }
        }
        .animation(.smooth(duration: 0.25), value: appState.phase)
    }
}

private struct BootstrapSplash: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.indigo.opacity(0.25), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                Text("Dark Matter")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white)
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)
            }
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

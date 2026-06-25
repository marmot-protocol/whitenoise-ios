import SwiftUI
import UIKit

@MainActor
private final class BackgroundRuntimeSuspensionTask {
    private var taskID: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        taskID = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                self?.endIfNeeded()
            }
        }
    }

    func endIfNeeded() {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }
}

@main
struct whitenoise_iosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(appState.toastState)
                .environment(appState.navigation)
                .appAppearance()
                .task {
                    appState.setAppSceneActive(scenePhase == .active)
                    await appState.bootstrap()
                }
                .onOpenURL { url in
                    appState.handle(url: url)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        appState.startForegroundActivation()
                    case .inactive:
                        appState.setAppSceneActive(false)
                    case .background:
                        beginBackgroundRuntimeSuspension()
                    @unknown default:
                        appState.setAppSceneActive(false)
                    }
                }
        }
    }

    @MainActor
    private func beginBackgroundRuntimeSuspension() {
        let backgroundTask = BackgroundRuntimeSuspensionTask(name: "Suspend Marmot runtime")
        let suspensionTask = appState.startRuntimeSuspension()
        Task { @MainActor in
            await suspensionTask.value
            backgroundTask.endIfNeeded()
        }
    }

}

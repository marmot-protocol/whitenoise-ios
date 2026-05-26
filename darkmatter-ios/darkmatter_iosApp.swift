import SwiftUI
import UIKit

@main
struct darkmatter_iosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
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
                        Task { await appState.resumeAfterForegroundActivation() }
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

    private func beginBackgroundRuntimeSuspension() {
        appState.setAppSceneActive(false)
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "Suspend Marmot runtime")
        Task {
            await appState.prepareForBackgroundSuspension()
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
            }
        }
    }
}

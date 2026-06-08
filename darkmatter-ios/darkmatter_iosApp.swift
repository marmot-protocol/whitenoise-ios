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
                .environment(appState.toastState)
                .environment(appState.navigation)
                .environment(appState.profileCache)
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

    private func beginBackgroundRuntimeSuspension() {
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "Suspend Marmot runtime") {
            // iOS is about to reclaim our remaining background time. End the task
            // ourselves so the app isn't terminated uncleanly mid-suspension (#81).
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
        let suspensionTask = appState.startRuntimeSuspension()
        Task {
            await suspensionTask.value
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
    }

}

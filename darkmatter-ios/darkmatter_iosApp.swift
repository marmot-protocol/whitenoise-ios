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
                        appState.startRuntimeSuspension()
                    case .background:
                        beginBackgroundRuntimeSuspension()
                    @unknown default:
                        appState.startRuntimeSuspension()
                    }
                }
        }
    }

    private func beginBackgroundRuntimeSuspension() {
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "Suspend Marmot runtime")
        let suspensionTask = appState.startRuntimeSuspension()
        Task {
            await suspensionTask.value
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
            }
        }
    }

}

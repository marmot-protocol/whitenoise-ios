import MarmotKit
import SwiftUI
import UIKit

enum SceneRuntimeAction: Equatable {
    case activate
    case remainInactive
    case suspend

    static func resolve(_ phase: ScenePhase) -> Self {
        switch phase {
        case .active:
            .activate
        case .inactive:
            .remainInactive
        case .background:
            .suspend
        @unknown default:
            .remainInactive
        }
    }
}

@MainActor
final class BackgroundRuntimeSuspensionTask {
    typealias BeginBackgroundTask = @MainActor (
        _ name: String,
        _ expirationHandler: @escaping @Sendable () -> Void
    ) -> UIBackgroundTaskIdentifier
    typealias EndBackgroundTask = @MainActor (_ taskID: UIBackgroundTaskIdentifier) -> Void

    private let endBackgroundTask: EndBackgroundTask
    private let onExpiration: @MainActor () -> Void
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var suspensionTask: Task<Void, Never>?
    private var endObserverTask: Task<Void, Never>?

    init(
        name: String,
        onExpiration: @escaping @MainActor () -> Void = {},
        beginBackgroundTask: BeginBackgroundTask = { name, expirationHandler in
            UIApplication.shared.beginBackgroundTask(
                withName: name,
                expirationHandler: expirationHandler
            )
        },
        endBackgroundTask: @escaping EndBackgroundTask = { taskID in
            UIApplication.shared.endBackgroundTask(taskID)
        }
    ) {
        self.endBackgroundTask = endBackgroundTask
        self.onExpiration = onExpiration
        taskID = beginBackgroundTask(name) { [weak self] in
            guard let owner = self else { return }
            Task { @MainActor in
                owner.expireIfNeeded()
            }
        }
    }

    func endWhenSuspensionCompletes(_ suspensionTask: Task<Void, Never>) {
        self.suspensionTask = suspensionTask
        beginEndObserverIfPossible()
    }

    func endIfNeeded() {
        guard taskID != .invalid else { return }
        let taskIDToEnd = taskID
        taskID = .invalid
        endObserverTask?.cancel()
        endObserverTask = nil
        endBackgroundTask(taskIDToEnd)
    }

    private func expireIfNeeded() {
        guard taskID != .invalid else { return }
        onExpiration()
        endIfNeeded()
    }

    private func beginEndObserverIfPossible() {
        guard endObserverTask == nil else { return }
        guard let suspensionTask else { return }
        endObserverTask = Task { @MainActor in
            await suspensionTask.value
            self.endIfNeeded()
        }
    }
}

@main
struct whitenoise_iosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState: AppState
    @State private var appearance: AppAppearanceStore
    @State private var appLockOverlay = AppLockOverlayPresenter()
    @State private var captureProtection = WindowCaptureProtection()

    init() {
        let appState = AppState()
        let appearance = AppAppearanceStore()
        _appState = State(initialValue: appState)
        _appearance = State(initialValue: appearance)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(appState.toastState)
                .environment(appState.navigation)
                .environment(appearance)
                .onChange(of: appState.appDataErasureGeneration) {
                    appearance.setTheme(.system)
                    AppLanguage.setCurrentRawValue(AppLanguage.system.rawValue)
                }
                .appAppearance(appearance)
                .task {
                    // The path monitor lives in this lazy singleton; touch it
                    // at launch so connectivity-restored events fire even in
                    // sessions that never read a media setting.
                    _ = MediaAutoDownloadStore.shared
                    handleScenePhase(scenePhase, isInitial: true)
                    appLockOverlay.update(
                        for: appState.appLock.shield,
                        controller: appState.appLock,
                        appearance: appearance
                    )
                    syncCaptureProtection()
                    await appState.bootstrap()
                }
                .onOpenURL { url in
                    appState.handle(url: url)
                }
                .onChange(of: scenePhase) { _, phase in
                    handleScenePhase(phase, isInitial: false)
                }
                .onReceive(NotificationCenter.default.publisher(for: MediaAutoDownloadStore.connectivityRestored)) { _ in
                    // Wake MDK's durable outbound retries before the ordinary
                    // relay catch-up when the path monitor sees the network return.
                    appState.scheduleConnectivityCatchUp(connectivityRestored: true)
                }
                .onChange(of: appState.activeAccount?.accountIdHex, initial: true) { _, accountIdHex in
                    MediaAutoDownloadStore.shared.setActiveAccount(accountIdHex)
                }
                .onChange(of: appState.appLock.shield) { _, shield in
                    appLockOverlay.update(
                        for: shield,
                        controller: appState.appLock,
                        appearance: appearance
                    )
                }
                .onChange(of: appState.blockScreenshots) { _, _ in
                    syncCaptureProtection()
                }
        }
    }

    @MainActor
    private func handleScenePhase(_ phase: ScenePhase, isInitial: Bool) {
        switch SceneRuntimeAction.resolve(phase) {
        case .activate:
            appState.appLock.handleScenePhaseActive()
            Task { await appState.appLock.requestUnlock() }
            if isInitial {
                appState.setAppSceneActive(true)
            } else {
                appState.startForegroundActivation()
            }
        case .remainInactive:
            appState.appLock.handleScenePhaseInactive()
            appState.setAppSceneActive(false)
        case .suspend:
            appState.appLock.handleScenePhaseBackground()
            beginBackgroundRuntimeSuspension()
        }
    }

    @MainActor
    private func beginBackgroundRuntimeSuspension() {
        let backgroundTask = BackgroundRuntimeSuspensionTask(name: "Suspend Marmot runtime")
        let suspensionTask = appState.startRuntimeSuspension()
        backgroundTask.endWhenSuspensionCompletes(suspensionTask)
    }

    @MainActor
    private func syncCaptureProtection() {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows
            .first { $0.isKeyWindow }
        captureProtection.setActive(appState.blockScreenshots, window: window)
    }

}

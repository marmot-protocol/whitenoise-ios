enum ForegroundNotificationSyncPolicy {
    static func shouldCatchUp(
        appPhase: AppState.Phase,
        isCatchUpRunning: Bool,
        isAppSceneActive: Bool,
        runtimeSuspendedForBackground: Bool,
        isRuntimeSuspending: Bool
    ) -> Bool {
        appPhase == .ready
            && !isCatchUpRunning
            && isAppSceneActive
            && !runtimeSuspendedForBackground
            && !isRuntimeSuspending
    }
}

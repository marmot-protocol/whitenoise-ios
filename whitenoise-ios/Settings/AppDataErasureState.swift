import Foundation

@MainActor @Observable
final class AppDataErasureState {
    // Avoid the task-local isolated-deinit crash on iOS 26.2 and older.
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {}

    static let persistentDefaults: UserDefaults = {
        let suite = (Bundle.main.bundleIdentifier ?? "dev.ipf.whitenoise.ios") + ".erasure-recovery"
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("Cannot open app erasure recovery preferences")
        }
        return defaults
    }()
    private static let key = "marmot.appDataErasurePending"
    private let defaults: UserDefaults
    private let legacyDefaults: UserDefaults?
    private(set) var needsRecovery: Bool
    private(set) var recoveryInProgress = false
    /// Once the recovery sheet opens, keep it mounted across transient
    /// `.inactive` runtime teardowns (so Retry's inline error isn't lost),
    /// releasing only on completion or handoff to startup failure.
    private(set) var recoveryPresented = false
    /// True while an unfinished erasure must keep surviving accounts out of
    /// normal activation and foreground maintenance until erasure completes.
    private(set) var blocksNormalAccountActivation: Bool

    init(defaults: UserDefaults, legacyDefaults: UserDefaults? = nil) {
        self.defaults = defaults
        self.legacyDefaults = legacyDefaults
        if legacyDefaults?.bool(forKey: Self.key) == true { defaults.set(true, forKey: Self.key) }
        let pending = defaults.bool(forKey: Self.key)
        needsRecovery = pending
        blocksNormalAccountActivation = pending
    }

    func shouldPresentRecovery(
        runtimeReady: Bool,
        phaseOwnsLiveRuntime: Bool = true
    ) -> Bool {
        guard phaseOwnsLiveRuntime else { return false }
        if recoveryInProgress { return true }
        return needsRecovery && (runtimeReady || recoveryPresented)
    }

    func noteRecoveryPresented() {
        recoveryPresented = true
    }

    func noteRecoveryDismissed() {
        recoveryPresented = false
    }

    func begin() {
        defaults.set(true, forKey: Self.key)
        blocksNormalAccountActivation = true
        let retryingFromRecovery = needsRecovery || recoveryPresented
        recoveryInProgress = retryingFromRecovery
        if retryingFromRecovery {
            recoveryPresented = true
        }
        needsRecovery = false
    }

    func failed() {
        recoveryInProgress = false
        needsRecovery = true
    }

    func complete() {
        defaults.removeObject(forKey: Self.key)
        legacyDefaults?.removeObject(forKey: Self.key)
        blocksNormalAccountActivation = false
        recoveryInProgress = false
        recoveryPresented = false
        needsRecovery = false
    }
}

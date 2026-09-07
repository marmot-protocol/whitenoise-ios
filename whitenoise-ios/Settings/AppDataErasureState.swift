import Foundation

@MainActor @Observable
final class AppDataErasureState {
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
    var needsRecovery: Bool
    private(set) var recoveryInProgress = false

    init(defaults: UserDefaults, legacyDefaults: UserDefaults? = nil) {
        self.defaults = defaults
        self.legacyDefaults = legacyDefaults
        if legacyDefaults?.bool(forKey: Self.key) == true { defaults.set(true, forKey: Self.key) }
        needsRecovery = defaults.bool(forKey: Self.key)
    }

    func shouldPresentRecovery(activeAccountRef: String?, runtimeReady: Bool) -> Bool {
        recoveryInProgress || (activeAccountRef == nil && needsRecovery && runtimeReady)
    }

    func begin() {
        defaults.set(true, forKey: Self.key)
        recoveryInProgress = needsRecovery
        needsRecovery = false
    }

    func failed() { recoveryInProgress = false; needsRecovery = true }

    func complete() {
        defaults.removeObject(forKey: Self.key)
        legacyDefaults?.removeObject(forKey: Self.key)
        recoveryInProgress = false
        needsRecovery = false
    }
}

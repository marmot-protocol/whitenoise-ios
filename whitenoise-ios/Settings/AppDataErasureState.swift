import Foundation

@MainActor @Observable
final class AppDataErasureState {
    private static let key = "marmot.appDataErasurePending"
    private let defaults: UserDefaults
    var needsRecovery: Bool

    init(defaults: UserDefaults) {
        self.defaults = defaults
        needsRecovery = defaults.bool(forKey: Self.key)
    }

    func begin() { defaults.set(true, forKey: Self.key); needsRecovery = false }
    func failed() { needsRecovery = true }
    func complete() { defaults.removeObject(forKey: Self.key); needsRecovery = false }
}

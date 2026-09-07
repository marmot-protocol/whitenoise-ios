import Foundation

@MainActor @Observable
final class DeviceDiagnosticsConsent {
    static let seenKey = "marmot.deviceDiagnosticsPromptSeen"
    private static let pendingKey = "marmot.deviceDiagnosticsPromptPending"
    private let defaults: UserDefaults
    private(set) var hasSeenPrompt: Bool
    private(set) var pending = false
    var onboardingVisible = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasSeenPrompt = defaults.bool(forKey: Self.seenKey)
        pending = defaults.bool(forKey: Self.pendingKey) && !hasSeenPrompt
    }

    func scheduleAfterSignIn() {
        if !hasSeenPrompt {
            pending = true
            defaults.set(true, forKey: Self.pendingKey)
        }
    }

    func canPresent(chatsVisible: Bool, anotherSheetVisible: Bool, runtimeReady: Bool) -> Bool {
        pending && !hasSeenPrompt && chatsVisible && !onboardingVisible && !anotherSheetVisible && runtimeReady
    }

    func complete() {
        hasSeenPrompt = true
        pending = false
        defaults.removeObject(forKey: Self.pendingKey)
        defaults.set(true, forKey: Self.seenKey)
    }

    func reset() {
        hasSeenPrompt = false
        pending = false
        defaults.removeObject(forKey: Self.pendingKey)
        defaults.removeObject(forKey: Self.seenKey)
    }
}

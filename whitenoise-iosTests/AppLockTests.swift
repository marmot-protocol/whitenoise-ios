import Foundation
import Testing
@testable import whitenoise_ios

@MainActor
struct AppLockTests {
    final class Clock {
        var now: Date

        init(_ now: Date = Date(timeIntervalSince1970: 1_000_000)) {
            self.now = now
        }

        func advance(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppLockTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeController(
        defaults: UserDefaults? = nil,
        clock: Clock = Clock(),
        authenticate: @escaping () async -> Bool = { true },
        capabilityAvailable: @escaping () -> Bool = { true }
    ) -> AppLockController {
        AppLockController(
            defaults: defaults ?? makeDefaults(),
            now: { clock.now },
            authenticate: authenticate,
            capabilityAvailable: capabilityAvailable
        )
    }

    @Test func startsDisabledUnlockedAndHidden() {
        let appLock = makeController()

        #expect(!appLock.isEnabled)
        #expect(!appLock.isLocked)
        #expect(appLock.shield == .hidden)
    }

    @Test func coldLaunchStartsLockedWhenEnabled() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppLockController.enabledKey)

        let appLock = makeController(defaults: defaults)

        #expect(appLock.isLocked)
        #expect(appLock.shield == .locked)
    }

    @Test func enablingRequiresSuccessfulAuthentication() async {
        let defaults = makeDefaults()
        let appLock = makeController(defaults: defaults, authenticate: { false })

        await appLock.setEnabled(true)

        #expect(!appLock.isEnabled)
        #expect(!defaults.bool(forKey: AppLockController.enabledKey))
    }

    @Test func enablingPersistsAfterSuccessfulAuthentication() async {
        let defaults = makeDefaults()
        let appLock = makeController(defaults: defaults)

        await appLock.setEnabled(true)

        #expect(appLock.isEnabled)
        #expect(!appLock.isLocked)
        #expect(defaults.bool(forKey: AppLockController.enabledKey))
    }

    @Test func immediateGraceLocksOnForegroundAfterBackground() async {
        let appLock = makeController()
        await appLock.setEnabled(true)

        appLock.handleScenePhaseInactive()
        appLock.handleScenePhaseBackground()
        appLock.handleScenePhaseActive()

        #expect(appLock.isLocked)
        #expect(appLock.shield == .locked)
    }

    @Test func graceWindowKeepsAppUnlockedWithinPeriod() async {
        let clock = Clock()
        let appLock = makeController(clock: clock)
        await appLock.setEnabled(true)
        await appLock.setGracePeriod(.oneMinute)

        appLock.handleScenePhaseBackground()
        clock.advance(30)
        appLock.handleScenePhaseActive()

        #expect(!appLock.isLocked)
        #expect(appLock.shield == .hidden)
    }

    @Test func graceWindowRestartsFromEachForegroundReturn() async {
        let clock = Clock()
        let appLock = makeController(clock: clock)
        await appLock.setEnabled(true)
        await appLock.setGracePeriod(.oneMinute)

        appLock.handleScenePhaseBackground()
        clock.advance(45)
        appLock.handleScenePhaseActive()
        appLock.handleScenePhaseBackground()
        clock.advance(45)
        appLock.handleScenePhaseActive()

        #expect(!appLock.isLocked)
    }

    @Test func graceWindowElapsedLocksOnForeground() async {
        let clock = Clock()
        let appLock = makeController(clock: clock)
        await appLock.setEnabled(true)
        await appLock.setGracePeriod(.oneMinute)

        appLock.handleScenePhaseBackground()
        clock.advance(61)
        appLock.handleScenePhaseActive()

        #expect(appLock.isLocked)
    }

    @Test func switcherPeekKeepsEarliestBackgroundAnchor() async {
        let clock = Clock()
        let appLock = makeController(clock: clock)
        await appLock.setEnabled(true)
        await appLock.setGracePeriod(.oneMinute)

        appLock.handleScenePhaseBackground()
        clock.advance(30)
        appLock.handleScenePhaseInactive()
        clock.advance(20)
        appLock.handleScenePhaseBackground()
        clock.advance(20)
        appLock.handleScenePhaseActive()

        #expect(appLock.isLocked)
    }

    @Test func inactiveSceneShowsCoverWithoutLocking() async {
        let appLock = makeController()
        await appLock.setEnabled(true)

        appLock.handleScenePhaseInactive()
        #expect(appLock.shield == .cover)

        appLock.handleScenePhaseActive()
        #expect(!appLock.isLocked)
        #expect(appLock.shield == .hidden)
    }

    @Test func coverStaysHiddenWhenDisabled() {
        let appLock = makeController()

        appLock.handleScenePhaseInactive()

        #expect(appLock.shield == .hidden)
    }

    @Test func unlockSucceedsAndHidesShield() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppLockController.enabledKey)
        let appLock = makeController(defaults: defaults)

        await appLock.requestUnlock()
        appLock.handleScenePhaseActive()

        #expect(!appLock.isLocked)
        #expect(appLock.shield == .hidden)
    }

    @Test func failedUnlockStaysLocked() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppLockController.enabledKey)
        let appLock = makeController(defaults: defaults, authenticate: { false })

        await appLock.requestUnlock()

        #expect(appLock.isLocked)
        #expect(appLock.shield == .locked)
    }

    @Test func unlockFailsOpenWithoutDeviceAuthCapability() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppLockController.enabledKey)
        let appLock = makeController(
            defaults: defaults,
            authenticate: { false },
            capabilityAvailable: { false }
        )

        await appLock.requestUnlock()

        #expect(!appLock.isLocked)
    }

    @Test func unlockedForegroundReturnDoesNotRelock() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppLockController.enabledKey)
        let appLock = makeController(defaults: defaults)

        await appLock.requestUnlock()
        appLock.handleScenePhaseActive()

        #expect(!appLock.isLocked)
    }

    @Test func disablingClearsLockState() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppLockController.enabledKey)
        let appLock = makeController(defaults: defaults)

        await appLock.setEnabled(false)

        #expect(!appLock.isEnabled)
        #expect(!appLock.isLocked)
        #expect(appLock.shield == .hidden)
        #expect(!defaults.bool(forKey: AppLockController.enabledKey))
    }

    @Test func disablingRequiresSuccessfulAuthentication() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppLockController.enabledKey)
        let appLock = makeController(defaults: defaults, authenticate: { false })

        await appLock.setEnabled(false)

        #expect(appLock.isEnabled)
        #expect(appLock.isLocked)
        #expect(defaults.bool(forKey: AppLockController.enabledKey))
    }

    @Test func disablingFailsOpenWithoutDeviceAuthCapability() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppLockController.enabledKey)
        let appLock = makeController(
            defaults: defaults,
            authenticate: { false },
            capabilityAvailable: { false }
        )

        await appLock.setEnabled(false)

        #expect(!appLock.isEnabled)
        #expect(!appLock.isLocked)
        #expect(!defaults.bool(forKey: AppLockController.enabledKey))
    }

    @Test func resetDisablesWithoutAuthentication() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppLockController.enabledKey)
        defaults.set(AppLockGracePeriod.fiveMinutes.rawValue, forKey: AppLockController.gracePeriodKey)
        var authenticated = false
        let appLock = makeController(defaults: defaults, authenticate: {
            authenticated = true
            return false
        })
        #expect(appLock.gracePeriod == .fiveMinutes)

        appLock.reset()

        #expect(!authenticated)
        #expect(!appLock.isEnabled)
        #expect(!appLock.isLocked)
        #expect(appLock.shield == .hidden)
        #expect(!defaults.bool(forKey: AppLockController.enabledKey))
        #expect(makeController(defaults: defaults).gracePeriod == .immediate)
    }

    @Test func gracePeriodPersistsAndResolves() async {
        let defaults = makeDefaults()
        let appLock = makeController(defaults: defaults)

        await appLock.setGracePeriod(.fiveMinutes)

        let reloaded = makeController(defaults: defaults)
        #expect(reloaded.gracePeriod == .fiveMinutes)
    }

    @Test func lengtheningGracePeriodKeepsTheOldValueWhenAuthenticationFails() async {
        let defaults = makeDefaults()
        let appLock = makeController(defaults: defaults, authenticate: { false })

        await appLock.setGracePeriod(.fifteenMinutes)

        #expect(appLock.gracePeriod == .immediate)
        #expect(makeController(defaults: defaults).gracePeriod == .immediate)
    }

    @Test func shorteningGracePeriodDoesNotPrompt() async {
        let defaults = makeDefaults()
        defaults.set(AppLockGracePeriod.fifteenMinutes.rawValue, forKey: AppLockController.gracePeriodKey)
        var authenticated = false
        let appLock = makeController(defaults: defaults, authenticate: {
            authenticated = true
            return false
        })

        await appLock.setGracePeriod(.oneMinute)

        #expect(!authenticated)
        #expect(appLock.gracePeriod == .oneMinute)
    }

    @Test func lengtheningGracePeriodFailsOpenWithoutDeviceAuthCapability() async {
        var authenticated = false
        let appLock = makeController(
            authenticate: {
                authenticated = true
                return false
            },
            capabilityAvailable: { false }
        )

        await appLock.setGracePeriod(.fiveMinutes)

        #expect(!authenticated)
        #expect(appLock.gracePeriod == .fiveMinutes)
    }

    @Test func unknownPersistedGracePeriodFallsBackToImmediate() {
        let defaults = makeDefaults()
        defaults.set(42, forKey: AppLockController.gracePeriodKey)

        let appLock = makeController(defaults: defaults)

        #expect(appLock.gracePeriod == .immediate)
    }
}

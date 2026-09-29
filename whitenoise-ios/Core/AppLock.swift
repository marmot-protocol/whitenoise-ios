import Foundation
import LocalAuthentication

/// How long the app may stay unlocked after it last left the foreground.
/// Raw value is the grace window in seconds (persisted to UserDefaults).
enum AppLockGracePeriod: Int, CaseIterable {
    case immediate = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    var seconds: TimeInterval { TimeInterval(rawValue) }

    var displayName: String {
        switch self {
        case .immediate: L10n.string("Immediately")
        case .oneMinute: L10n.string("After 1 minute")
        case .fiveMinutes: L10n.string("After 5 minutes")
        case .fifteenMinutes: L10n.string("After 15 minutes")
        }
    }

    static func resolved(rawValue: Int?) -> AppLockGracePeriod {
        guard let rawValue, let period = AppLockGracePeriod(rawValue: rawValue) else {
            return .immediate
        }
        return period
    }
}

/// Pure lock/shield decisions, extracted from the controller so the
/// scene-phase state machine is testable without LocalAuthentication.
enum AppLockPolicy {
    static func shouldLockOnForeground(
        enabled: Bool,
        backgroundedAt: Date?,
        gracePeriod: AppLockGracePeriod,
        now: Date
    ) -> Bool {
        guard enabled, let backgroundedAt else { return false }
        return now.timeIntervalSince(backgroundedAt) >= gracePeriod.seconds
    }

    static func shouldShowPrivacyCover(enabled: Bool, sceneActive: Bool) -> Bool {
        enabled && !sceneActive
    }
}

/// Whether device-owner authentication (biometrics or passcode) can run at
/// all, and which biometry the hardware offers. Drives the settings labels.
nonisolated struct AppLockCapability {
    let available: Bool
    let biometryType: LABiometryType

    static func current() -> AppLockCapability {
        let context = LAContext()
        let available = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        return AppLockCapability(available: available, biometryType: context.biometryType)
    }
}

/// Owns the app-lock preference and the locked/covered UI state. Purely a
/// presentation shield: it never touches the Marmot runtime, which suspends
/// and resumes on the scene phase independently of the lock.
@MainActor
@Observable
final class AppLockController {
    /// What the overlay window should show right now.
    enum Shield {
        case hidden
        /// Opaque splash-style cover while the scene is inactive (app
        /// switcher, system alerts) so content never appears in snapshots.
        case cover
        /// The cover plus an unlock affordance; authentication is required.
        case locked
    }

    private(set) var isEnabled: Bool
    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false

    var gracePeriod: AppLockGracePeriod {
        didSet {
            HostSettingsSaveTiming.measure { defaults.set(gracePeriod.rawValue, forKey: Self.gracePeriodKey) }
        }
    }

    private var isSceneActive = true
    /// Set when the app last entered the background; the grace window is
    /// measured from here. Memory-only on purpose: a cold launch with the
    /// lock enabled always starts locked.
    private var backgroundedAt: Date?

    private let defaults: UserDefaults
    private let now: () -> Date
    private let authenticate: () async -> Bool
    private let capabilityAvailable: () -> Bool

    static let enabledKey = "marmot.appLock.enabled"
    static let gracePeriodKey = "marmot.appLock.gracePeriod"

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        authenticate: @escaping () async -> Bool = AppLockController.systemAuthenticate,
        capabilityAvailable: @escaping () -> Bool = { AppLockCapability.current().available }
    ) {
        self.defaults = defaults
        self.now = now
        self.authenticate = authenticate
        self.capabilityAvailable = capabilityAvailable
        let enabled = defaults.bool(forKey: Self.enabledKey)
        self.isEnabled = enabled
        self.isLocked = enabled
        self.gracePeriod = AppLockGracePeriod.resolved(
            rawValue: defaults.object(forKey: Self.gracePeriodKey) as? Int
        )
    }

    var shield: Shield {
        if isLocked { return .locked }
        if AppLockPolicy.shouldShowPrivacyCover(enabled: isEnabled, sceneActive: isSceneActive) {
            return .cover
        }
        return .hidden
    }

    /// Enabling proves authentication works before the preference sticks, so
    /// the user can't lock themselves out behind a policy that never passes.
    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled, !isAuthenticating else { return }
        if enabled {
            guard await runAuthentication() else { return }
        }
        isEnabled = enabled
        HostSettingsSaveTiming.measure { defaults.set(enabled, forKey: Self.enabledKey) }
        if !enabled {
            isLocked = false
            backgroundedAt = nil
        }
    }

    func handleScenePhaseActive() {
        isSceneActive = true
        if AppLockPolicy.shouldLockOnForeground(
            enabled: isEnabled,
            backgroundedAt: backgroundedAt,
            gracePeriod: gracePeriod,
            now: now()
        ) {
            isLocked = true
        }
        backgroundedAt = nil
    }

    func handleScenePhaseInactive() {
        isSceneActive = false
    }

    func handleScenePhaseBackground() {
        isSceneActive = false
        // Keep the earliest anchor across switcher peeks that background the
        // scene again without an active foreground in between.
        if isEnabled, backgroundedAt == nil {
            backgroundedAt = now()
        }
    }

    func requestUnlock() async {
        guard isLocked, !isAuthenticating else { return }
        // Without a device passcode the policy can never pass; fail open
        // rather than locking the owner out permanently.
        guard capabilityAvailable() else {
            isLocked = false
            backgroundedAt = nil
            return
        }
        if await runAuthentication() {
            isLocked = false
            backgroundedAt = nil
        }
    }

    private func runAuthentication() async -> Bool {
        isAuthenticating = true
        defer { isAuthenticating = false }
        return await authenticate()
    }

    private static func systemAuthenticate() async -> Bool {
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: L10n.string("Unlock White Noise")
            )
        } catch {
            return false
        }
    }
}

import Observation
import SwiftUI
import Synchronization
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
struct AppearanceThemeTests {
    @Test func persistedRawValuesStayStable() {
        // Stored in UserDefaults, so renaming a case is a breaking change.
        #expect(AppearanceTheme.system.rawValue == "system")
        #expect(AppearanceTheme.light.rawValue == "light")
        #expect(AppearanceTheme.dark.rawValue == "dark")
        #expect(AppearanceTheme.legacyTrueBlackRawValue == "trueBlack")
    }

    @Test func everyThemeRoundTripsThroughItsRawValue() {
        for theme in AppearanceTheme.allCases {
            #expect(AppearanceTheme.resolved(rawValue: theme.rawValue) == theme)
        }
    }

    @Test func unknownAndMissingRawValuesFallBackToSystem() {
        #expect(AppearanceTheme.resolved(rawValue: nil) == .system)
        #expect(AppearanceTheme.resolved(rawValue: "") == .system)
        #expect(AppearanceTheme.resolved(rawValue: "amoled") == .system)
        #expect(AppearanceTheme.resolved(rawValue: "TrueBlack") == .system)
        #expect(AppearanceTheme.resolved(rawValue: "trueBlack") == .dark)
    }

    @Test func everyThemeRoundTripsThroughUserDefaults() throws {
        let suiteName = "appearance-theme-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for theme in AppearanceTheme.allCases {
            defaults.set(theme.rawValue, forKey: AppearanceTheme.storageKey)
            let stored = defaults.string(forKey: AppearanceTheme.storageKey)
            #expect(AppearanceTheme.resolved(rawValue: stored) == theme)
        }
    }

    @Test func preferredColorSchemesMatchSupportedThemes() {
        #expect(AppearanceTheme.system.preferredColorScheme == nil)
        #expect(AppearanceTheme.light.preferredColorScheme == .light)
        #expect(AppearanceTheme.dark.preferredColorScheme == .dark)
    }

    @Test func userInterfaceStylesMatchSupportedThemes() {
        #expect(AppearanceTheme.system.userInterfaceStyle == .unspecified)
        #expect(AppearanceTheme.light.userInterfaceStyle == .light)
        #expect(AppearanceTheme.dark.userInterfaceStyle == .dark)
    }

    @Test func pickerOffersOnlySystemLightAndDark() {
        #expect(AppearanceTheme.allCases == [.system, .light, .dark])
    }

    @Test func appearanceSelectionMigratesStoredTrueBlackToDark() {
        let selection = AppAppearanceSelection(themeRawValue: "trueBlack", languageRawValue: nil)
        #expect(selection.theme == .dark)
        #expect(selection.preferredColorScheme == .dark)
    }

    @Test func sharedStorePublishesAndAppliesThemeImmediately() throws {
        let suiteName = "appearance-store-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var appliedThemes: [AppearanceTheme] = []
        let store = AppAppearanceStore(
            defaults: defaults,
            themeApplier: { appliedThemes.append($0) }
        )
        let observation = AppearanceObservationProbe()

        withObservationTracking {
            _ = store.theme
        } onChange: {
            observation.recordChange()
        }
        store.setTheme(.dark)

        #expect(observation.changeCount == 1)
        #expect(store.theme == .dark)
        #expect(defaults.string(forKey: AppearanceTheme.storageKey) == AppearanceTheme.dark.rawValue)
        #expect(appliedThemes == [.dark])
    }

    @Test func sharedStoreMigratesLegacyThemeDuringInitialization() throws {
        let suiteName = "appearance-store-migration-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppearanceTheme.legacyTrueBlackRawValue, forKey: AppearanceTheme.storageKey)

        let store = AppAppearanceStore(defaults: defaults, themeApplier: { _ in })

        #expect(store.theme == .dark)
        #expect(defaults.string(forKey: AppearanceTheme.storageKey) == AppearanceTheme.dark.rawValue)
    }

    @Test func returningToSystemClearsForcedWindowStyle() {
        let window = UIWindow()

        AppAppearanceRuntime.apply(theme: .light, to: [window])
        #expect(window.overrideUserInterfaceStyle == .light)

        AppAppearanceRuntime.apply(theme: .system, to: [window])
        #expect(window.overrideUserInterfaceStyle == .unspecified)
    }
}

private final class AppearanceObservationProbe: Sendable {
    private let changes = Mutex(0)

    var changeCount: Int {
        changes.withLock { $0 }
    }

    func recordChange() {
        changes.withLock { $0 += 1 }
    }
}

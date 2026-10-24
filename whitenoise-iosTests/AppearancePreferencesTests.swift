import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct AppearancePreferencesTests {
    @Test func themePreferencesResolveToExpectedColorSchemes() {
        #expect(AppearanceTheme.resolved(rawValue: nil) == .system)
        #expect(AppearanceTheme.resolved(rawValue: "nope") == .system)
        #expect(AppearanceTheme.resolved(rawValue: "trueBlack") == .dark)
        #expect(AppearanceTheme.system.preferredColorScheme == nil)
        #expect(AppearanceTheme.light.preferredColorScheme == .light)
        #expect(AppearanceTheme.dark.preferredColorScheme == .dark)
        #expect(AppearanceTheme.system.userInterfaceStyle == .unspecified)
        #expect(AppearanceTheme.light.userInterfaceStyle == .light)
        #expect(AppearanceTheme.dark.userInterfaceStyle == .dark)
    }

    @Test func languagePreferencesCoverSupportedCatalogLocales() {
        let localeIDs = AppLanguage.supportedAppLanguages.compactMap(\.localeIdentifier)

        #expect(AppLanguage.resolved(rawValue: nil) == .system)
        #expect(AppLanguage.resolved(rawValue: "nope") == .system)
        #expect(AppLanguage.system.localeIdentifier == nil)
        #expect(localeIDs == ["en", "de", "es", "fr", "it", "pt", "ru", "tr", "zh-Hans", "zh-Hant"])
    }

    @Test func systemLanguageDisplayNameUsesSelectedAppLanguage() {
        withAppLanguage(.french) {
            #expect(AppLanguage.system.displayName == "Système")
        }
    }

    @Test func languageChangeNotificationCarriesLanguageInUserInfoNotObject() throws {
        let suiteName = "dev.ipf.WhiteNoise.language-notification-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = NotificationCenter()

        var received: Notification?
        let observer = notificationCenter.addObserver(
            forName: AppLanguage.didChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            received = notification
        }
        defer { notificationCenter.removeObserver(observer) }

        AppLanguage.setCurrentRawValue(
            AppLanguage.french.rawValue,
            defaults: defaults,
            notificationCenter: notificationCenter
        )

        let notification = try #require(received)
        #expect(defaults.string(forKey: AppLanguage.storageKey) == "fr")
        #expect(notification.object == nil)
        #expect(notification.userInfo?[AppLanguage.didChangeLanguageUserInfoKey] as? String == "fr")
    }

    @Test func appAppearanceSelectionResolvesThemeAndLanguageTogether() {
        let selected = AppAppearanceSelection(themeRawValue: "dark", languageRawValue: "fr")
        let fallback = AppAppearanceSelection(themeRawValue: "unknown", languageRawValue: "unknown")

        #expect(selected.theme == .dark)
        #expect(selected.preferredColorScheme == .dark)
        #expect(selected.language == .french)
        #expect(selected.locale.identifier == "fr")
        #expect(fallback.theme == .system)
        #expect(fallback.preferredColorScheme == nil)
        #expect(fallback.language == .system)
    }
}

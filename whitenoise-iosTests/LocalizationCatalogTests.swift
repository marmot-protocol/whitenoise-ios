import Testing
import Foundation
@testable import whitenoise_ios

/// Runtime localization behaviour and the built app's permission strings.
/// Static catalog checks (every locale translated, placeholders preserved,
/// plural variations, InfoPlist keys, no English fallback) run in the lint job
/// through `scripts/check-localization-catalog.py`.
struct LocalizationCatalogTests {
    private let expectedLocales = ["de", "es", "fr", "it", "pt", "ru", "tr", "zh-Hans", "zh-Hant"]

    @Test func formattedLocalizationUsesStaticCatalogKeys() {
        #expect(
            L10n.plural(
                "%lld members",
                Int64(3),
                locale: Locale(identifier: "de")
            ) == "3 Mitglieder"
        )
        #expect(
            L10n.plural(
                "Invited %lld members",
                Int64(3),
                locale: Locale(identifier: "it")
            ) == "3 membri invitati"
        )
        #expect(
            L10n.plural(
                "Published %lld updates.",
                Int64(2),
                locale: Locale(identifier: "zh-Hans")
            ) == "已发布 2 个更新。"
        )
        #expect(
            L10n.plural(
                "Your kind:0 metadata is live on %lld relays.",
                Int64(4),
                locale: Locale(identifier: "de")
            ) == "Ihre kind:0-Metadaten sind auf 4 Relays live."
        )
        #expect(
            L10n.plural(
                "%lld person group",
                Int64(3),
                locale: Locale(identifier: "it")
            ) == "Gruppo di 3 persone"
        )
        #expect(
            L10n.plural(
                "Published %lld updates.",
                Int64(5),
                locale: Locale(identifier: "ru")
            ) == "Опубликовано 5 обновлений."
        )
    }

    @Test func bundleLookupIsResolvedOncePerBaseAndPreferenceUntilTheLanguageChanges() {
        let notificationCenter = NotificationCenter()
        let cache = L10nBundleCache(notificationCenter: notificationCenter)
        let probe = Bundle(for: L10nBundleCacheProbe.self)
        var resolutions = 0
        // Resolves to a bundle other than the base, so a hit that returns the
        // base instead of the stored bundle is caught.
        @discardableResult
        func lookUp(_ preference: String, in base: Bundle) -> Bundle {
            cache.bundle(forPreference: preference, in: base) {
                resolutions += 1
                return base === probe ? Bundle.main : probe
            }
        }

        let resolved = lookUp("fr", in: probe)
        #expect(resolved === Bundle.main)
        #expect(lookUp("fr", in: probe) === resolved)
        #expect(resolutions == 1)

        lookUp("de", in: probe)
        lookUp("fr", in: .main)
        #expect(resolutions == 3)
        lookUp("fr", in: probe)
        #expect(resolutions == 3)

        notificationCenter.post(name: AppLanguage.didChangeNotification, object: nil)
        lookUp("fr", in: probe)
        #expect(resolutions == 4)
    }

    @Test func permissionDescriptionsMatchBuiltAppAndCoverEveryLanguage() throws {
        let catalog = try readCatalog("whitenoise-ios/InfoPlist.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])
        let info = try #require(Bundle.main.infoDictionary)
        let usageKeys = info.keys.filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") }
        #expect(usageKeys.contains("NSPhotoLibraryAddUsageDescription"))
        #expect(usageKeys.contains("NSLocationWhenInUseUsageDescription"))
        for key in usageKeys {
            let purpose = try #require(info[key] as? String)
            #expect(try localizedValue(key, locale: "en", in: strings) == purpose)
            for locale in expectedLocales {
                #expect(!(try localizedValue(key, locale: locale, in: strings)).isEmpty)
                #expect(try localizedState(key, locale: locale, in: strings) == "translated")
            }
        }
    }

    private func readCatalog(_ relativePath: String) throws -> [String: Any] {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func localizedValue(_ key: String, locale: String, in strings: [String: Any]) throws -> String {
        try stringUnit(key, locale: locale, in: strings, field: "value")
    }

    private func localizedState(_ key: String, locale: String, in strings: [String: Any]) throws -> String {
        try stringUnit(key, locale: locale, in: strings, field: "state")
    }

    private func stringUnit(_ key: String, locale: String, in strings: [String: Any], field: String) throws -> String {
        let entry = try #require(strings[key] as? [String: Any], "Missing localization key: \(key)")
        let localizations = try #require(entry["localizations"] as? [String: Any], "Missing localizations for \(key)")
        let localeEntry = try #require(localizations[locale] as? [String: Any], "Missing \(locale) localization for \(key)")
        let stringUnit = try #require(localeEntry["stringUnit"] as? [String: Any], "Missing string unit for \(key) in \(locale)")
        return try #require(stringUnit[field] as? String, "Missing \(field) for \(key) in \(locale)")
    }
}

private final class L10nBundleCacheProbe {}

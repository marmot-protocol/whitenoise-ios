import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct LocalizationCatalogTests {
    private let expectedLocales = ["de", "es", "fr", "it", "pt", "ru", "tr", "zh-Hans", "zh-Hant"]

    @Test func sharedCatalogCoversLaunchLanguagesAndCoreKeys() throws {
        let catalog = try readCatalog("Shared/Localizable.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])
        let expectedKeys = [
            "Settings",
            "Notifications",
            "New Chat",
            "Message",
            "Appearance",
            "Theme",
            "Light",
            "Dark",
            "System",
            "Language",
            "Preferences",
            "Draft: %@",
            "Edit Description",
            "Shared Media",
            "New encrypted message",
            "That QR code isn't a White Noise profile.",
            "Couldn't create chat",
            "Mark as unread",
            "Pin",
            "Pinned",
            "Unpin",
            "Updating chat…",
            "Couldn't mark as unread",
            "Couldn't update pin",
            "Push registration failed",
            "Support",
            "Chat with support",
            "Connecting to support…",
            "Couldn't connect to support",
            "Please check your connection and try again.",
            "Leave “%@”?",
            "You'll stop receiving new messages. This chat will remain on this device as read-only history until you delete it.",
            "Leaving…",
            "Sign Up",
            "Choose Avatar",
            "Change Avatar",
            "Remove Avatar",
            "Name",
            "About (Optional)",
            "Signing Up…",
            "Couldn’t create your account. Please try again.",
            "Couldn’t save your profile details. Please try again.",
            "Continue",
            "Your avatar is public. The photo is uploaded to a public service, and removing it from your profile may not delete the uploaded copy.",
            "This image is too large. Choose an image smaller than 25 MB.",
            "We couldn’t read this image. Choose another image.",
            "New profile",
            "Profile avatar preview",
            "Selected profile photo",
            "Camera Access Is Off",
            "Allow camera access in Settings to take photos and videos.",
            "Camera Is Restricted",
            "Camera access is restricted on this iPhone.",
            "Camera Unavailable",
            "The camera isn’t available on this iPhone right now."
        ]

        for key in expectedKeys {
            let entry = try #require(strings[key] as? [String: Any], "Missing localization key: \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for locale in expectedLocales {
                #expect(localizations[locale] != nil, "Missing \(locale) localization for \(key)")
            }
        }
    }

    @Test func sharedCatalogHasFilledTranslationsForRepresentativeVisibleKeys() throws {
        let catalog = try readCatalog("Shared/Localizable.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])
        let expectedTranslations: [String: [String: String]] = [
            "Save profile": [
                "de": "Profil speichern",
                "es": "Guardar perfil",
                "fr": "Enregistrer le profil",
                "it": "Salva profilo",
                "pt": "Salvar perfil",
                "ru": "Сохранить профиль",
                "tr": "Profili kaydet",
                "zh-Hans": "保存个人资料",
                "zh-Hant": "儲存個人資料"
            ],
            "Couldn't load chats": [
                "de": "Chats konnten nicht geladen werden",
                "es": "No se pudieron cargar los chats",
                "fr": "Impossible de charger les discussions",
                "it": "Impossibile caricare le chat",
                "pt": "Não foi possível carregar os bate-papos",
                "ru": "Не удалось загрузить чаты",
                "tr": "Sohbetler yüklenemedi",
                "zh-Hans": "无法加载聊天记录",
                "zh-Hant": "無法載入聊天記錄"
            ]
        ]

        for (key, translations) in expectedTranslations {
            for (locale, expected) in translations {
                #expect(try localizedValue(key, locale: locale, in: strings) == expected)
            }
        }
    }

    @Test func welcomeEntryPointButtonsAreTranslatedInEveryShippedLocale() throws {
        let catalog = try readCatalog("Shared/Localizable.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])
        let expectedTranslations: [String: [String: String]] = [
            "Sign In": [
                "de": "Anmelden",
                "es": "Iniciar sesión",
                "fr": "Se connecter",
                "it": "Accedi",
                "pt": "Entrar",
                "ru": "Войти",
                "tr": "Oturum Aç",
                "zh-Hans": "登录",
                "zh-Hant": "登入"
            ],
            "Sign Up": [
                "de": "Registrieren",
                "es": "Registrarse",
                "fr": "S’inscrire",
                "it": "Registrati",
                "pt": "Cadastrar-se",
                "ru": "Зарегистрироваться",
                "tr": "Kaydol",
                "zh-Hans": "注册",
                "zh-Hant": "註冊"
            ]
        ]

        for (key, translations) in expectedTranslations {
            for locale in expectedLocales {
                let expected = try #require(
                    translations[locale],
                    "No expected \(locale) translation declared for \(key)"
                )
                #expect(try localizedValue(key, locale: locale, in: strings) == expected)
                #expect(
                    try localizedState(key, locale: locale, in: strings) == "translated",
                    "\(key) is not marked translated in \(locale)"
                )
            }
        }
    }

    @Test(arguments: [false, true])
    func localizedLeavesReadBothPluralFormats(usesSubstitution: Bool) throws {
        let key = "%lld items"
        let forms: [String: Any] = [
            "one": ["stringUnit": ["state": "translated", "value": "%lld item"]],
            "other": ["stringUnit": ["state": "needs_review", "value": "%lld items"]]
        ]
        let variations: [String: Any] = ["plural": forms]
        let localeEntry: [String: Any] = usesSubstitution ? [
            "stringUnit": ["state": "translated", "value": "%#@count@"],
            "substitutions": ["count": ["variations": variations]]
        ] : ["variations": variations]
        let strings: [String: Any] = [key: ["localizations": ["en": localeEntry]]]

        let leaves = try localizedLeaves(key, locale: "en", in: strings)
        let pluralLeaves = leaves.filter { !$0.isSubstitutionShell }
        #expect(pluralLeaves.count == 2)
        #expect(Set(pluralLeaves.map(\.value)) == ["%lld item", "%lld items"])
        #expect(Set(pluralLeaves.map(\.state)) == ["translated", "needs_review"])
        #expect(leaves.filter(\.isSubstitutionShell).count == (usesSubstitution ? 1 : 0))
    }

    @Test func groupRetentionStringsAreTranslatedInEveryShippedLocale() throws {
        let catalog = try readCatalog("Shared/Localizable.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])
        let expectedTranslations: [String: [String: String]] = [
            "Disappearing messages": [
                "de": "Verschwindende Nachrichten",
                "es": "Mensajes temporales",
                "fr": "Messages éphémères",
                "it": "Messaggi effimeri",
                "pt": "Mensagens temporárias",
                "ru": "Исчезающие сообщения",
                "tr": "Kaybolan mesajlar",
                "zh-Hans": "阅后即焚消息",
                "zh-Hant": "限時訊息"
            ],
            "Off": [
                "de": "Aus",
                "es": "Desactivado",
                "fr": "Désactivé",
                "it": "Disattivato",
                "pt": "Desativado",
                "ru": "Выкл.",
                "tr": "Kapalı",
                "zh-Hans": "关闭",
                "zh-Hant": "關閉"
            ],
            "Messages are kept until you delete them.": [
                "de": "Nachrichten bleiben erhalten, bis du sie löschst.",
                "es": "Los mensajes se conservan hasta que los elimines.",
                "fr": "Les messages sont conservés jusqu’à ce que vous les supprimiez.",
                "it": "I messaggi vengono conservati finché non li elimini.",
                "pt": "As mensagens são mantidas até você apagá-las.",
                "ru": "Сообщения хранятся, пока вы их не удалите.",
                "tr": "Mesajlar siz silene kadar saklanır.",
                "zh-Hans": "消息会一直保留，直到你删除它们。",
                "zh-Hant": "訊息會一直保留，直到你刪除為止。"
            ]
        ]

        for (key, translations) in expectedTranslations {
            for locale in expectedLocales {
                let expected = try #require(
                    translations[locale],
                    "No expected \(locale) translation declared for \(key)"
                )
                #expect(try localizedValue(key, locale: locale, in: strings) == expected)
                #expect(
                    try localizedState(key, locale: locale, in: strings) == "translated",
                    "\(key) is not marked translated in \(locale)"
                )
            }
        }
    }

    /// `sharedCatalogMarksEveryLocaleTranslated` passes on a row that carries the
    /// English source at `state: "translated"`, which is how the whole
    /// disappearing-messages family once shipped untranslated in all nine locales.
    @Test func groupRetentionStringsDoNotFallBackToEnglishCopy() throws {
        let catalog = try readCatalog("Shared/Localizable.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])
        let retentionKeys = [
            "Disappearing messages",
            "Off",
            "Messages are kept until you delete them.",
            "Messages are deleted for everyone after the selected time.",
            "Custom",
            "Duration",
            "Unit",
            "Seconds",
            "Minutes",
            "Hours",
            "Days",
            "Weeks",
            "Enter a duration between %@ and %@.",
            "Delete older messages?",
            "Set Timer",
            "This timer also applies to messages already in the chat. Everything older than %@ will be deleted immediately.",
            "Updating disappearing messages…",
            "Disappearing messages updated",
            "Couldn't update disappearing messages"
        ]
        // "Minutes" is spelled identically in English and French.
        let sharedSpellings: Set<String> = ["Minutes|fr"]

        for key in retentionKeys {
            let english = try localizedValue(key, locale: "en", in: strings)
            for locale in expectedLocales where !sharedSpellings.contains("\(key)|\(locale)") {
                #expect(
                    try localizedValue(key, locale: locale, in: strings) != english,
                    "\(key) still shows English copy in \(locale)"
                )
            }
        }
    }

    @Test func sharedCatalogHasNoMissingLocalizedValuesAndKeepsPlaceholders() throws {
        let catalog = try readCatalog("Shared/Localizable.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])

        for (key, rawEntry) in strings {
            _ = try #require(rawEntry as? [String: Any], "Invalid localization entry: \(key)")
            let expectedPlaceholders = placeholders(in: key)
            for locale in expectedLocales {
                let values = try localizedLeaves(key, locale: locale, in: strings)
                    .filter { !$0.isSubstitutionShell }
                    .map(\.value)
                for value in values {
                    if !key.isEmpty {
                        #expect(!value.isEmpty, "Missing \(locale) value for \(key)")
                    }
                    #expect(
                        placeholders(in: value).sorted() == expectedPlaceholders.sorted(),
                        "Broken placeholders for \(key) in \(locale)"
                    )
                }
                if !key.isEmpty {
                    #expect(!values.isEmpty, "Missing \(locale) values for \(key)")
                }
            }
        }
    }

    @Test func sharedCatalogMarksEveryLocaleTranslated() throws {
        let catalog = try readCatalog("Shared/Localizable.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])

        for (key, rawEntry) in strings {
            _ = try #require(rawEntry as? [String: Any], "Invalid localization entry: \(key)")
            for locale in expectedLocales {
                for leaf in try localizedLeaves(key, locale: locale, in: strings) {
                    #expect(
                        leaf.state == "translated",
                        "Untranslated \(locale) value for \(key) (state: \(leaf.state))"
                    )
                }
            }
        }
    }

    @Test func countLocalizationsUsePluralVariations() throws {
        let catalog = try readCatalog("Shared/Localizable.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])
        let pluralKeys = [
            "%lld members",
            "%lld person group",
            "%lld more messages",
            "%llu unread messages",
            "📎 %lld attachments",
            "Invited %lld members",
            "Published %lld updates.",
            "Your kind:0 metadata is live on %lld relays.",
            "You can send up to %lld photos at once"
        ]

        for key in pluralKeys {
            for locale in ["en"] + expectedLocales {
                let categories = try pluralCategories(key, locale: locale, in: strings)
                #expect(categories.contains("other"), "\(key) in \(locale) is missing an `other` plural form")
                if locale == "ru" {
                    #expect(categories.isSuperset(of: ["one", "few", "many", "other"]))
                }
            }
        }
    }

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

    @Test func localizationBundleLookupIsMemoizedForSelectedLanguage() {
        let bundle = Bundle(for: L10nBundleCacheProbe.self)
        L10n.resetBundleCacheForTesting()
        #expect(L10n.bundleCacheCountForTesting(in: bundle) == 0)
        _ = L10n.formatted(
            "Settings",
            arguments: [],
            locale: Locale(identifier: "fr"),
            baseBundle: bundle
        )
        #expect(L10n.bundleCacheCountForTesting(in: bundle) == 1)
        _ = L10n.formatted(
            "Done",
            arguments: [],
            locale: Locale(identifier: "fr"),
            baseBundle: bundle
        )
        #expect(L10n.bundleCacheCountForTesting(in: bundle) == 1)
    }

    @Test func infoPlistCatalogLocalizesCameraPermissionCopy() throws {
        let catalog = try readCatalog("whitenoise-ios/InfoPlist.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])
        let cameraUsage = try #require(strings["NSCameraUsageDescription"] as? [String: Any])
        let localizations = try #require(cameraUsage["localizations"] as? [String: Any])

        let english = try localizedValue("NSCameraUsageDescription", locale: "en", in: strings)
        #expect(english != "NSCameraUsageDescription")
        #expect(english == "White Noise uses the camera to scan profile QR codes and take photos and videos for encrypted chats.")
        #expect(localizations["fr"] != nil)
        #expect(localizations["zh-Hant"] != nil)
    }

    @Test func infoPlistCatalogCoversLaunchLanguages() throws {
        let catalog = try readCatalog("whitenoise-ios/InfoPlist.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])

        // CFBundleDisplayName is flavor-specific (`WN_DISPLAY_NAME`). Xcode's IDE
        // auto-extracts a development-language placeholder (`state` "new",
        // resolved against the Release-Production default config) into this
        // catalog on every build, and there is no build setting that suppresses
        // it. That placeholder is NOT compiled into the built app's
        // `.lproj/InfoPlist.strings`, so it cannot override the flavor display
        // name (verified: a Staging build with the entry present still ships
        // "WN Staging" with no localized override). Only a *translated*
        // localization would actually hide staging, so fail on that alone
        // rather than on the harmless auto-extracted placeholder.
        if let displayName = strings["CFBundleDisplayName"] as? [String: Any] {
            let localizations = (displayName["localizations"] as? [String: Any]) ?? [:]
            for (locale, entry) in localizations {
                let state = ((entry as? [String: Any])?["stringUnit"] as? [String: Any])?["state"] as? String
                #expect(
                    state != "translated",
                    "CFBundleDisplayName must not carry a translated value (\(locale)); it would hide the flavor display name."
                )
            }
        }

        for key in ["CFBundleName", "NSCameraUsageDescription", "NSMicrophoneUsageDescription",
                    "NSFaceIDUsageDescription", "NSLocationWhenInUseUsageDescription", "NSPhotoLibraryAddUsageDescription"] {
            for locale in ["en"] + expectedLocales {
                #expect(!(try localizedValue(key, locale: locale, in: strings)).isEmpty)
            }
        }
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
        let entry = try #require(strings[key] as? [String: Any], "Missing localization key: \(key)")
        let localizations = try #require(entry["localizations"] as? [String: Any], "Missing localizations for \(key)")
        let localeEntry = try #require(localizations[locale] as? [String: Any], "Missing \(locale) localization for \(key)")
        let stringUnit = try #require(localeEntry["stringUnit"] as? [String: Any], "Missing string unit for \(key) in \(locale)")
        return try #require(stringUnit["value"] as? String, "Missing value for \(key) in \(locale)")
    }

    private func localizedState(_ key: String, locale: String, in strings: [String: Any]) throws -> String {
        let entry = try #require(strings[key] as? [String: Any], "Missing localization key: \(key)")
        let localizations = try #require(entry["localizations"] as? [String: Any], "Missing localizations for \(key)")
        let localeEntry = try #require(localizations[locale] as? [String: Any], "Missing \(locale) localization for \(key)")
        let stringUnit = try #require(localeEntry["stringUnit"] as? [String: Any], "Missing string unit for \(key) in \(locale)")
        return try #require(stringUnit["state"] as? String, "Missing state for \(key) in \(locale)")
    }

    private struct LocalizedLeaf {
        let state: String
        let value: String
        let isSubstitutionShell: Bool
    }

    private func localizedLeaves(_ key: String, locale: String, in strings: [String: Any]) throws -> [LocalizedLeaf] {
        let entry = try #require(strings[key] as? [String: Any], "Missing localization key: \(key)")
        let localizations = try #require(entry["localizations"] as? [String: Any], "Missing localizations for \(key)")
        let localeEntry = try #require(localizations[locale] as? [String: Any], "Missing \(locale) localization for \(key)")
        let substitutions = (localeEntry["substitutions"] as? [String: Any]) ?? [:]

        var leaves: [LocalizedLeaf] = []
        if let stringUnit = localeEntry["stringUnit"] as? [String: Any] {
            leaves.append(
                LocalizedLeaf(
                    state: try #require(stringUnit["state"] as? String, "Missing state for \(key) in \(locale)"),
                    value: try #require(stringUnit["value"] as? String, "Missing value for \(key) in \(locale)"),
                    isSubstitutionShell: !substitutions.isEmpty
                )
            )
        }

        var pluralVariations: [[String: Any]] = []
        if let variations = localeEntry["variations"] as? [String: Any] {
            pluralVariations.append(try #require(variations["plural"] as? [String: Any]))
        }
        for rawSubstitution in substitutions.values {
            let substitution = try #require(rawSubstitution as? [String: Any])
            let variations = try #require(substitution["variations"] as? [String: Any])
            pluralVariations.append(try #require(variations["plural"] as? [String: Any]))
        }
        for plural in pluralVariations {
            for rawForm in plural.values {
                let form = try #require(rawForm as? [String: Any])
                let stringUnit = try #require(form["stringUnit"] as? [String: Any])
                leaves.append(
                    LocalizedLeaf(
                        state: try #require(stringUnit["state"] as? String, "Missing state for \(key) in \(locale)"),
                        value: try #require(stringUnit["value"] as? String, "Missing value for \(key) in \(locale)"),
                        isSubstitutionShell: false
                    )
                )
            }
        }

        return leaves
    }

    private func pluralCategories(_ key: String, locale: String, in strings: [String: Any]) throws -> Set<String> {
        let entry = try #require(strings[key] as? [String: Any], "Missing localization key: \(key)")
        let localizations = try #require(entry["localizations"] as? [String: Any], "Missing localizations for \(key)")
        let localeEntry = try #require(localizations[locale] as? [String: Any], "Missing \(locale) localization for \(key)")
        let substitutions = try #require(localeEntry["substitutions"] as? [String: Any])
        let count = try #require(substitutions["count"] as? [String: Any])
        let variations = try #require(count["variations"] as? [String: Any])
        let plural = try #require(variations["plural"] as? [String: Any])
        return Set(plural.keys)
    }

    private func placeholders(in value: String) -> [String] {
        let pattern = #"%[@a-zA-Z0-9]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: value) else { return nil }
            return String(value[swiftRange])
        }
    }
}

private final class L10nBundleCacheProbe {}

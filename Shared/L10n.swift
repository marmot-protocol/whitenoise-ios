import Foundation

nonisolated enum L10n {
    static func string(_ value: String.LocalizationValue) -> String {
        let language = AppLanguage.current
        let locale = language.locale ?? .autoupdatingCurrent
        return String(localized: value, bundle: bundle(for: language), locale: locale)
    }

    static func formatted(_ value: String.LocalizationValue, _ arguments: CVarArg...) -> String {
        let language = AppLanguage.current
        let locale = language.locale ?? .autoupdatingCurrent
        return formatted(
            value,
            arguments: arguments,
            locale: locale,
            baseBundle: bundle(for: language)
        )
    }

    static func formatted(
        _ value: String.LocalizationValue,
        arguments: [CVarArg],
        locale: Locale,
        baseBundle: Bundle = .main
    ) -> String {
        let format = String(
            localized: value,
            bundle: bundle(for: locale, in: baseBundle),
            locale: locale
        )
        return String(format: format, locale: locale, arguments: arguments)
    }

    static func plural(_ value: String.LocalizationValue, _ count: Int64) -> String {
        let language = AppLanguage.current
        let locale = language.locale ?? .autoupdatingCurrent
        return plural(value, count, locale: locale, baseBundle: bundle(for: language))
    }

    static func plural(_ value: String.LocalizationValue, _ count: UInt64) -> String {
        let language = AppLanguage.current
        let locale = language.locale ?? .autoupdatingCurrent
        return plural(value, count, locale: locale, baseBundle: bundle(for: language))
    }

    static func plural(
        _ value: String.LocalizationValue,
        _ count: Int64,
        locale: Locale,
        baseBundle: Bundle = .main
    ) -> String {
        let format = String(
            localized: value,
            bundle: bundle(for: locale, in: baseBundle),
            locale: locale
        )
        return withVaList([count]) {
            NSString(format: format, locale: locale, arguments: $0) as String
        }
    }

    static func plural(
        _ value: String.LocalizationValue,
        _ count: UInt64,
        locale: Locale,
        baseBundle: Bundle = .main
    ) -> String {
        let format = String(
            localized: value,
            bundle: bundle(for: locale, in: baseBundle),
            locale: locale
        )
        return withVaList([count]) {
            NSString(format: format, locale: locale, arguments: $0) as String
        }
    }

    private static func bundle(for language: AppLanguage, in base: Bundle = .main) -> Bundle {
        guard let localeIdentifier = language.localeIdentifier else { return base }
        return localizedBundle(forPreferences: [localeIdentifier], in: base)
    }

    private static func bundle(for locale: Locale, in base: Bundle) -> Bundle {
        localizedBundle(forPreferences: [locale.identifier], in: base)
    }

    private static func localizedBundle(forPreferences preferences: [String], in base: Bundle) -> Bundle {
        guard let localization = Bundle.preferredLocalizations(
            from: base.localizations,
            forPreferences: preferences
        ).first,
            let path = base.path(forResource: localization, ofType: "lproj"),
            let localized = Bundle(path: path)
        else { return base }
        return localized
    }
}

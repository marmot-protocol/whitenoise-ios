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
        return bundleCache.bundle(forPreference: localeIdentifier, in: base) {
            localizedBundle(forPreferences: [localeIdentifier], in: base)
        }
    }

    private static func bundle(for locale: Locale, in base: Bundle) -> Bundle {
        bundleCache.bundle(forPreference: locale.identifier, in: base) {
            localizedBundle(forPreferences: [locale.identifier], in: base)
        }
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

    private static let bundleCache = L10nBundleCache()
}

// L10n remains synchronous; NSLock guards all mutable cache state across actors.
// swiftlint:disable:next no_unchecked_sendable
nonisolated final class L10nBundleCache: @unchecked Sendable {
    private struct Key: Hashable {
        let base: ObjectIdentifier
        let preference: String
    }

    private let lock = NSLock()
    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?
    private var bundles: [Key: Bundle] = [:]

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        observer = notificationCenter.addObserver(
            forName: AppLanguage.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.removeAll()
        }
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }

    func bundle(forPreference preference: String, in base: Bundle, resolve: () -> Bundle) -> Bundle {
        let key = Key(base: ObjectIdentifier(base), preference: preference)
        lock.lock()
        if let cached = bundles[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = resolve()

        lock.lock()
        if let cached = bundles[key] {
            lock.unlock()
            return cached
        }
        bundles[key] = resolved
        lock.unlock()
        return resolved
    }

    private func removeAll() {
        lock.lock()
        bundles.removeAll()
        lock.unlock()
    }
}

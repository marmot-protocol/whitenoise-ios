import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case german = "de"
    case spanish = "es"
    case french = "fr"
    case italian = "it"
    case portuguese = "pt"
    case russian = "ru"
    case turkish = "tr"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"

    static let storageKey = "appearance.language"
    static let didChangeNotification = Notification.Name("AppLanguageDidChange")
    static let didChangeLanguageUserInfoKey = "language"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: AppContainerConfig.appGroupIdentifier) ?? .standard
    }

    static var supportedAppLanguages: [AppLanguage] {
        [
            .english,
            .german,
            .spanish,
            .french,
            .italian,
            .portuguese,
            .russian,
            .turkish,
            .chineseSimplified,
            .chineseTraditional
        ]
    }

    static var pickerChoices: [AppLanguage] {
        [.system] + supportedAppLanguages
    }

    static var current: AppLanguage {
        resolved(rawValue: currentRawValue)
    }

    static var currentRawValue: String {
        defaults.string(forKey: storageKey) ?? AppLanguage.system.rawValue
    }

    static var currentLocale: Locale {
        current.locale ?? .autoupdatingCurrent
    }

    static func resolved(rawValue: String?) -> AppLanguage {
        rawValue.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    static func setCurrentRawValue(_ rawValue: String) {
        let resolved = resolved(rawValue: rawValue).rawValue
        defaults.set(resolved, forKey: storageKey)
        NotificationCenter.default.post(
            name: didChangeNotification,
            object: nil,
            userInfo: [didChangeLanguageUserInfoKey: resolved]
        )
    }

    var id: String { rawValue }

    var localeIdentifier: String? {
        switch self {
        case .system:
            nil
        default:
            rawValue
        }
    }

    var locale: Locale? {
        localeIdentifier.map(Locale.init(identifier:))
    }

    var displayName: String {
        switch self {
        case .system:
            "System"
        case .english:
            "English"
        case .german:
            "Deutsch"
        case .spanish:
            "Español"
        case .french:
            "Français"
        case .italian:
            "Italiano"
        case .portuguese:
            "Português"
        case .russian:
            "Русский"
        case .turkish:
            "Türkçe"
        case .chineseSimplified:
            "简体中文"
        case .chineseTraditional:
            "繁體中文"
        }
    }
}

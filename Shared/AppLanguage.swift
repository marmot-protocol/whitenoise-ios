import Foundation

nonisolated enum AppLanguage: String, CaseIterable, Identifiable {
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
        if let testDefaults {
            return testDefaults
        }
        return UserDefaults(suiteName: AppContainerConfig.appGroupIdentifier) ?? .standard
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
        #if DEBUG
        if let testCurrentOverride { return testCurrentOverride }
        #endif
        return resolved(rawValue: currentRawValue)
    }

    #if DEBUG
    /// Task-scoped language override for tests. Parallel suites share the
    /// process-scoped `testDefaults`, so a test that wrote the preference
    /// there would leak its language into concurrently-running assertions on
    /// other suites; a task-local is visible only inside the test that set it.
    @TaskLocal static var testCurrentOverride: AppLanguage?
    #endif

    static var currentRawValue: String {
        defaults.string(forKey: storageKey) ?? AppLanguage.system.rawValue
    }

    static var currentLocale: Locale {
        current.locale ?? .autoupdatingCurrent
    }

    static func resolved(rawValue: String?) -> AppLanguage {
        rawValue.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    static func setCurrentRawValue(
        _ rawValue: String,
        defaults: UserDefaults = AppLanguage.defaults,
        notificationCenter: NotificationCenter = .default
    ) {
        let resolved = resolved(rawValue: rawValue).rawValue
        HostSettingsSaveTiming.measure { defaults.set(resolved, forKey: storageKey) }
        notificationCenter.post(
            name: didChangeNotification,
            object: nil,
            userInfo: [didChangeLanguageUserInfoKey: resolved]
        )
    }

    private static let testDefaults: UserDefaults? = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        else { return nil }

        let suiteName = [
            AppContainerConfig.appGroupIdentifier,
            "unit-tests",
            String(ProcessInfo.processInfo.processIdentifier)
        ].joined(separator: ".")
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.removePersistentDomain(forName: suiteName)
        return defaults
    }()

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
            L10n.string("System")
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

import Observation
import SwiftUI
import UIKit

struct AppAppearanceSelection: Equatable {
    let theme: AppearanceTheme
    let language: AppLanguage

    init(themeRawValue: String?, languageRawValue: String?) {
        self.theme = AppearanceTheme.resolved(rawValue: themeRawValue)
        self.language = AppLanguage.resolved(rawValue: languageRawValue)
    }

    var locale: Locale {
        language.locale ?? .autoupdatingCurrent
    }

    var preferredColorScheme: ColorScheme? {
        theme.preferredColorScheme
    }
}

@MainActor
@Observable
final class AppAppearanceStore {
    typealias ThemeApplier = @MainActor (AppearanceTheme) -> Void

    private let defaults: UserDefaults
    private let themeApplier: ThemeApplier
    private(set) var theme: AppearanceTheme

    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            defaults: defaults,
            themeApplier: { theme in
                AppAppearanceRuntime.apply(theme: theme)
            }
        )
    }

    init(
        defaults: UserDefaults,
        themeApplier: @escaping ThemeApplier
    ) {
        self.defaults = defaults
        self.themeApplier = themeApplier
        let storedRawValue = defaults.string(forKey: AppearanceTheme.storageKey)
        self.theme = AppearanceTheme.resolved(rawValue: storedRawValue)
        if storedRawValue == AppearanceTheme.legacyTrueBlackRawValue {
            defaults.set(AppearanceTheme.dark.rawValue, forKey: AppearanceTheme.storageKey)
        }
    }

    func setTheme(_ theme: AppearanceTheme) {
        guard self.theme != theme else { return }
        self.theme = theme
        defaults.set(theme.rawValue, forKey: AppearanceTheme.storageKey)
        themeApplier(theme)
    }

    func applyCurrentTheme() {
        themeApplier(theme)
    }
}

private struct AppAppearanceModifier: ViewModifier {
    let appearance: AppAppearanceStore
    @State private var languageRawValue = AppLanguage.currentRawValue

    private var selection: AppAppearanceSelection {
        AppAppearanceSelection(
            themeRawValue: appearance.theme.rawValue,
            languageRawValue: languageRawValue
        )
    }

    func body(content: Content) -> some View {
        content
            .tint(.accentColor)
            .environment(\.locale, selection.locale)
            .onAppear {
                languageRawValue = AppLanguage.currentRawValue
                appearance.applyCurrentTheme()
            }
            .onReceive(NotificationCenter.default.publisher(for: AppLanguage.didChangeNotification)) { _ in
                languageRawValue = AppLanguage.currentRawValue
            }
    }
}

private struct EnvironmentAppAppearanceModifier: ViewModifier {
    @Environment(AppAppearanceStore.self) private var appearance

    func body(content: Content) -> some View {
        content.modifier(AppAppearanceModifier(appearance: appearance))
    }
}

@MainActor
enum AppAppearanceRuntime {
    static func apply(theme: AppearanceTheme) {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        apply(theme: theme, to: windows)
    }

    static func apply(theme: AppearanceTheme, to windows: [UIWindow]) {
        let style = theme.userInterfaceStyle
        for window in windows {
            // A window override includes all presented content. Keeping the
            // override here avoids stale SwiftUI sheet preferences.
            window.overrideUserInterfaceStyle = style
            window.tintColor = UIColor(named: "AccentColor")
        }
    }
}

extension View {
    func appAppearance() -> some View {
        modifier(EnvironmentAppAppearanceModifier())
    }

    func appAppearance(_ appearance: AppAppearanceStore) -> some View {
        modifier(AppAppearanceModifier(appearance: appearance))
    }
}

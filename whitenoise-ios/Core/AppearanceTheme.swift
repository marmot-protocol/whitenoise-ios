import SwiftUI
import UIKit

enum AppearanceTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearance.theme"

    static func resolved(rawValue: String?) -> AppearanceTheme {
        rawValue.flatMap(AppearanceTheme.init(rawValue:)) ?? .system
    }

    var id: String { rawValue }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system:
            .unspecified
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }
}

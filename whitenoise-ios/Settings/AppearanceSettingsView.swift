import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(AppAppearanceStore.self) private var appearance
    @State private var languageRawValue = AppLanguage.currentRawValue
    @State private var linkPreviewSettings = LinkPreviewSettingsStore.shared

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: themeSelection) {
                    ForEach(AppearanceTheme.allCases) { theme in
                        Text(theme.displayName)
                            .tag(theme)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Theme")
            } footer: {
                Text("Match your device’s appearance or choose light or dark.")
            }

            Section {
                Picker("Language", selection: languageSelection) {
                    ForEach(AppLanguage.pickerChoices) { language in
                        if language == .system {
                            Text("System")
                                .tag(language.rawValue)
                        } else {
                            Text(language.displayName)
                                .tag(language.rawValue)
                        }
                    }
                }
                .pickerStyle(.navigationLink)
            } footer: {
                Text("Match your device’s language or choose another.")
            }

            Section {
                WNToggle(
                    "Show Link Previews",
                    isOn: Binding(
                        get: { linkPreviewSettings.showsPreviews },
                        set: { linkPreviewSettings.setShowsPreviews($0) }
                    )
                )
            } footer: {
                Text("Show link titles and images in chats. Loading previews shares your IP address with the linked website and image host.")
            }
        }
        .localizedNavigationTitle("Appearance")
        .productScreen(.settings, section: .appearance)
        .onAppear {
            languageRawValue = AppLanguage.currentRawValue
        }
        .onReceive(NotificationCenter.default.publisher(for: AppLanguage.didChangeNotification)) { notification in
            languageRawValue = notification.userInfo?[AppLanguage.didChangeLanguageUserInfoKey] as? String
                ?? AppLanguage.currentRawValue
        }
    }

    private var themeSelection: Binding<AppearanceTheme> {
        Binding {
            appearance.theme
        } set: { theme in
            appearance.setTheme(theme)
        }
    }

    private var languageSelection: Binding<String> {
        Binding {
            languageRawValue
        } set: { newValue in
            languageRawValue = newValue
            AppLanguage.setCurrentRawValue(newValue)
        }
    }
}

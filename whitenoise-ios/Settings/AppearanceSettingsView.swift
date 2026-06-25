import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage(AppearanceTheme.storageKey) private var themeRawValue = AppearanceTheme.system.rawValue
    @State private var languageRawValue = AppLanguage.currentRawValue

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $themeRawValue) {
                    ForEach(AppearanceTheme.allCases) { theme in
                        Text(theme.displayName)
                            .tag(theme.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Theme")
            } footer: {
                Text("Choose whether White Noise follows your device appearance or always uses a light or dark theme.")
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
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Language")
            } footer: {
                Text("System follows your device language. Other choices update White Noise immediately.")
            }
        }
        .navigationTitle("Appearance")
        .onAppear {
            languageRawValue = AppLanguage.currentRawValue
        }
        .onReceive(NotificationCenter.default.publisher(for: AppLanguage.didChangeNotification)) { _ in
            languageRawValue = AppLanguage.currentRawValue
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

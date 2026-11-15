import SwiftUI
import UIKit

/// The hold-to-dictate switch and the state of the speech model it needs.
@available(iOS 26.0, *)
struct DictationSettingsSection: View {
    @State private var preferences = ComposerDictationPreferenceStore.shared
    @State private var installer = DictationModelInstaller.shared

    var body: some View {
        Section {
            WNToggle(
                "Hold to Dictate",
                isOn: Binding(
                    get: { preferences.isEnabled },
                    set: { preferences.setEnabled($0) }
                )
            )
            if preferences.isEnabled {
                LabeledContent {
                    statusLabel
                } label: {
                    Text("Speech Model")
                }
                if installer.status == .notInstalled || installer.status == .failed {
                    Button {
                        installer.install(localeIdentifiers: Self.languages)
                    } label: {
                        Text("Download Speech Model")
                    }
                }
            }
        } header: {
            Text("Dictation")
        } footer: {
            Text("When the keyboard is hidden, hold the message field and speak, then let go to send. Slide up to keep listening, or slide left to cancel. iOS turns your speech into text on this device and downloads its speech model from Apple. The audio isn’t saved or sent.")
        }
        .task(id: preferences.isEnabled) {
            guard preferences.isEnabled else { return }
            await installer.refresh(localeIdentifiers: Self.languages)
            // Turning dictation on is the request for its model.
            if installer.status == .notInstalled {
                installer.install(localeIdentifiers: Self.languages)
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch installer.status {
        case .unknown, .checking:
            Text("Checking…")
        case .ready:
            Text("Ready")
        case .notInstalled:
            Text("Not Downloaded")
        case .downloading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading…")
            }
        case .unsupportedLanguage:
            Text("Not available for your language")
        case .failed:
            Text("Couldn’t download")
        }
    }

    /// Settings has no keyboard of its own, so it uses the enabled keyboards.
    private static var languages: [String] {
        DictationLocalePolicy.candidateIdentifiers(
            lastKeyboardLanguage: nil,
            activeKeyboardLanguages: UITextInputMode.activeInputModes.compactMap(\.primaryLanguage),
            preferredLanguages: Locale.preferredLanguages
        )
    }
}

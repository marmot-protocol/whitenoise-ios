import SwiftUI
import UIKit

/// Keeps copy confirmation on the initiating control, including for VoiceOver.
struct WNCopyButton<Label: View>: View {
    let value: String
    let accessibilityTitle: String
    @ViewBuilder let label: (Bool) -> Label
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            UIPasteboard.general.string = value
            Haptics.selection()
            copied = true
            AccessibilityNotification.Announcement(L10n.string("Copied")).post()
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                copied = false
                resetTask = nil
            }
        } label: {
            label(copied)
        }
        .accessibilityLabel(copied ? L10n.string("Copied") : accessibilityTitle)
        .onChange(of: value) { clearFeedback() }
        .onDisappear(perform: clearFeedback)
    }

    private func clearFeedback() {
        resetTask?.cancel()
        resetTask = nil
        copied = false
    }
}

import SwiftUI
import UIKit

nonisolated enum WNCopyFeedback {
    static let resetDelay = Duration.seconds(2)

    static func symbolName(isCopied: Bool) -> String {
        isCopied ? "checkmark" : "doc.on.doc"
    }

    static func accessibilityLabel(isCopied: Bool, copyTitle: String) -> String {
        isCopied ? L10n.string("Copied") : copyTitle
    }
}

/// Reserve the copy glyph's space while showing its confirmation.
struct WNCopyIcon: View {
    let copied: Bool

    var body: some View {
        Image(systemName: WNCopyFeedback.symbolName(isCopied: false))
            .hidden()
            .overlay {
                Image(systemName: WNCopyFeedback.symbolName(isCopied: copied))
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityHidden(true)
    }
}

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
                try? await Task.sleep(for: WNCopyFeedback.resetDelay)
                guard !Task.isCancelled else { return }
                copied = false
                resetTask = nil
            }
        } label: {
            label(copied)
        }
        .accessibilityLabel(WNCopyFeedback.accessibilityLabel(isCopied: copied, copyTitle: accessibilityTitle))
        .accessibilityInputLabels([Text(accessibilityTitle)])
        .onChange(of: value) { clearFeedback() }
        .onDisappear(perform: clearFeedback)
    }

    private func clearFeedback() {
        resetTask?.cancel()
        resetTask = nil
        copied = false
    }
}

#Preview("WNCopyButton") {
    Form {
        WNCopyButton(value: "npub1example", accessibilityTitle: "Copy npub") { copied in
            WNCopyIcon(copied: copied)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .tint(.primary)

        WNCopyButton(value: "a1b2c3d4e5f60718", accessibilityTitle: "Copy Group ID") { copied in
            LabeledContent("Group ID") {
                HStack {
                    Text("a1b2c3d4e5f60718")
                        .font(.callout.monospaced())
                    WNCopyIcon(copied: copied)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

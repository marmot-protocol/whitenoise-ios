import SwiftUI

nonisolated enum WNNeutralAccent {
    /// Labels on an accent-filled surface must invert with its appearance.
    static let foreground = Color(uiColor: .systemBackground)

    static func color(for colorScheme: ColorScheme) -> Color {
        WNButton.Metrics.accent(for: colorScheme)
    }
}

private struct WNNeutralAccentTint: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.tint(WNNeutralAccent.color(for: colorScheme))
    }
}

extension View {
    func wnNeutralAccentTint() -> some View {
        modifier(WNNeutralAccentTint())
    }
}

#Preview("WNNeutralAccentTint — Light") {
    WNNeutralAccentTintPreview()
}

#Preview("WNNeutralAccentTint — Dark") {
    WNNeutralAccentTintPreview()
        .preferredColorScheme(.dark)
}

private struct WNNeutralAccentTintPreview: View {
    @State private var selection = 0

    var body: some View {
        VStack(spacing: 32) {
            Picker("Mode", selection: $selection) {
                Text("Share").tag(0)
                Text("Connect").tag(1)
            }
            .labelsHidden()
            .pickerStyle(.palette)
            .controlSize(.extraLarge)
            .frame(width: 180)

            ShareLink(item: "marmot://profile/npub1example") {
                Label("Share Profile", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
            }
        }
        .wnNeutralAccentTint()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

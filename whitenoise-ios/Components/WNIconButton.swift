import SwiftUI

/// The icon-only companion to `WNButton`: the same monochrome chrome and
/// emphasis vocabulary, drawn as a circle so a bare glyph keeps a round tap
/// target instead of a stretched pill.
struct WNIconButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    /// Also the accessibility label — the glyph carries no text of its own.
    let title: LocalizedStringKey
    let systemImage: String
    var emphasis = WNButton.Emphasis.secondary
    let action: () -> Void

    var body: some View {
        // A toolbar already supplies liquid glass on iOS 26, so an explicit
        // glass style draws a second disc inside it. Stay plain there and match
        // the sibling toolbar buttons; the pre-26 fallback still needs chrome.
        if #available(iOS 26.0, *), emphasis == .secondary {
            Button(action: action) {
                Label(title, systemImage: systemImage)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.primary)
            }
        } else {
            Button(action: action) {
                Label(title, systemImage: systemImage)
                    .labelStyle(.iconOnly)
                    .wnButtonContentColor(
                        emphasis,
                        colorScheme: colorScheme,
                        isEnabled: isEnabled
                    )
            }
            .wnIconButtonStyle(emphasis)
            .wnButtonChrome(.circle, emphasis: emphasis)
        }
    }
}

private extension View {
    @ViewBuilder
    func wnIconButtonStyle(_ emphasis: WNButton.Emphasis) -> some View {
        switch emphasis {
        case .primary:
            wnPrimaryButtonStyle()
        case .secondary:
            wnSecondaryButtonStyle(.circle)
        }
    }
}

#Preview("WNIconButton — Light") {
    HStack(spacing: 24) {
        WNIconButton(title: "Back", systemImage: "chevron.backward") {}
        WNIconButton(title: "Close", systemImage: "xmark") {}
        WNIconButton(title: "Add", systemImage: "plus", emphasis: .primary) {}
        WNIconButton(title: "Back", systemImage: "chevron.backward") {}
            .disabled(true)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
}

#Preview("WNIconButton — Dark") {
    HStack(spacing: 24) {
        WNIconButton(title: "Back", systemImage: "chevron.backward") {}
        WNIconButton(title: "Close", systemImage: "xmark") {}
        WNIconButton(title: "Add", systemImage: "plus", emphasis: .primary) {}
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    .preferredColorScheme(.dark)
}

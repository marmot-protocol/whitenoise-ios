import SwiftUI

/// The icon-only companion to `WNButton`: the same monochrome chrome and
/// emphasis vocabulary, drawn as a circle so a bare glyph keeps a round tap
/// target instead of a stretched pill.
struct WNIconButton: View {
    /// Who draws the surface behind the glyph. An iOS 26 toolbar already draws
    /// liquid glass around its items, so a button that keeps its own circle
    /// there stacks a second one inside the first — but a toolbar item that
    /// hides the shared background (`sharedBackgroundVisibility(.hidden)`) has
    /// nothing to inherit and must keep drawing its own.
    nonisolated enum Chrome: Equatable {
        case own
        case container
    }

    nonisolated static func inheritsContainerSurface(
        emphasis: WNButton.Emphasis,
        chrome: Chrome
    ) -> Bool {
        emphasis == .secondary && chrome == .container
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    /// Also the accessibility label — the glyph carries no text of its own.
    let title: LocalizedStringKey
    let systemImage: String
    var emphasis = WNButton.Emphasis.secondary
    var chrome = Chrome.own
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *),
           Self.inheritsContainerSurface(emphasis: emphasis, chrome: chrome) {
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
                        size: .compact,
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

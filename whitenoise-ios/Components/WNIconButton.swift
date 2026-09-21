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

    /// Also the accessibility label — the glyph carries no text of its own.
    let title: LocalizedStringKey
    let systemImage: String
    var emphasis = WNButton.Emphasis.secondary
    var chrome = Chrome.own
    let action: () -> Void

    var body: some View {
        Button(role: WNButton.Metrics.role(for: emphasis), action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .wnIconButtonChrome(emphasis: emphasis, chrome: chrome)
    }
}

/// The `WNIconButton` surface, applied to a button-like view that cannot be a
/// `WNIconButton` because it carries its own action — `ShareLink`, for one.
private struct WNIconButtonChrome: ViewModifier {
    let emphasis: WNButton.Emphasis
    let chrome: WNIconButton.Chrome

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *),
           WNIconButton.inheritsContainerSurface(emphasis: emphasis, chrome: chrome) {
            content.foregroundStyle(.primary)
        } else {
            content.buttonStyle(WNStandaloneIconButtonStyle(emphasis: emphasis))
        }
    }
}

extension View {
    func wnIconButtonChrome(
        emphasis: WNButton.Emphasis = .secondary,
        chrome: WNIconButton.Chrome = .own
    ) -> some View {
        modifier(WNIconButtonChrome(emphasis: emphasis, chrome: chrome))
    }
}

private struct WNStandaloneIconButtonStyle: ButtonStyle {
    let emphasis: WNButton.Emphasis
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var diameter = WNSecondaryButtonStyle.Metrics.circleDiameter

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .imageScale(.large)
            .foregroundStyle(WNButton.Metrics.contentColor(
                emphasis: emphasis, colorScheme: colorScheme, isEnabled: isEnabled))
            .frame(width: diameter, height: diameter)
            .contentShape(.circle)
            .modifier(WNIconSurface(emphasis: emphasis, colorScheme: colorScheme))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct WNIconSurface: ViewModifier {
    let emphasis: WNButton.Emphasis
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        if emphasis == .secondary {
            if #available(iOS 26.0, *) {
                content.compatibleInputCircleChrome()
            } else {
                content.wnLiftedChrome(in: Circle())
            }
        } else {
            content
                .background(WNButton.Metrics.tint(for: emphasis, colorScheme: colorScheme), in: Circle())
                .wnProminentIconGlass()
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

private extension View {
    @ViewBuilder
    func wnProminentIconGlass() -> some View {
        if #available(iOS 26.0, *) {
            compatibleInputCircleChrome()
        } else {
            self
        }
    }
}

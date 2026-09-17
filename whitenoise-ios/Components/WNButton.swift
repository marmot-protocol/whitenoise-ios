import SwiftUI

struct WNButton: View {
    nonisolated enum Emphasis: Equatable {
        case primary
        case secondary
        /// A filled red action that destroys data. Carries `ButtonRole` so the
        /// intent survives for assistive technology, not just the fill.
        case destructive
    }

    /// `large` is the full-width call to action at the bottom of a screen.
    /// `standard` is full width too but one step shorter, for an action that
    /// sits inside a `Form` section rather than under the whole screen.
    /// `compact` hugs its label so the same chrome fits a toolbar or a row.
    nonisolated enum Size: Equatable {
        case large
        case standard
        case compact
    }

    nonisolated enum Metrics {
        static let fallbackLabelMinHeight: CGFloat = 44

        static func accent(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white : .black
        }

        static func contentColor(
            emphasis: Emphasis,
            colorScheme: ColorScheme,
            isEnabled: Bool
        ) -> Color {
            guard isEnabled else { return .secondary }

            switch emphasis {
            case .primary:
                return colorScheme == .dark ? .black : .white
            case .secondary:
                return accent(for: colorScheme)
            case .destructive:
                // The red fill does not flip with the scheme, so the label
                // cannot either without losing contrast in one of them.
                return .white
            }
        }

        static func tint(for emphasis: Emphasis, colorScheme: ColorScheme) -> Color {
            emphasis == .destructive ? .red : accent(for: colorScheme)
        }

        static func controlSize(for size: Size) -> ControlSize {
            switch size {
            case .large: .extraLarge
            case .standard: .large
            case .compact: .regular
            }
        }

        static func role(for emphasis: Emphasis) -> ButtonRole? {
            emphasis == .destructive ? .destructive : nil
        }

        /// A compact secondary button is a toolbar item, and an iOS 26 toolbar
        /// already draws liquid glass around its items; styling it again stacks
        /// a second capsule inside the first. Every other combination stands on
        /// its own and has to paint its own surface.
        static func drawsOwnSurface(emphasis: Emphasis, size: Size) -> Bool {
            !(emphasis == .secondary && size == .compact)
        }

        /// Both full-width sizes claim the whole row; only a compact button,
        /// which lives in a toolbar, stays as wide as its title.
        static func stretches(_ size: Size) -> Bool {
            size != .compact
        }
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let title: LocalizedStringKey
    var systemImage: String?
    var emphasis = Emphasis.primary
    var size = Size.large
    var isLoading = false
    let action: () -> Void

    var body: some View {
        let contentColor = Metrics.contentColor(
            emphasis: emphasis,
            colorScheme: colorScheme,
            isEnabled: isEnabled
        )

        return Button(role: Metrics.role(for: emphasis), action: action) {
            ZStack {
                WNButtonTitle(title: title, systemImage: systemImage)
                    .opacity(isLoading ? 0 : 1)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(contentColor)
                        .transition(.opacity)
                }
            }
            .wnButtonContentColor(
                emphasis,
                size: size,
                colorScheme: colorScheme,
                isEnabled: isEnabled
            )
            .animation(.default, value: isLoading)
            .wnButtonLabelSizing(size)
        }
        .wnButtonStyle(emphasis, size: size)
        .wnButtonChrome(emphasis: emphasis)
        .controlSize(Metrics.controlSize(for: size))
        .wnButtonSizing(size)
        .allowsHitTesting(!isLoading)
    }
}

private struct WNButtonTitle: View {
    let title: LocalizedStringKey
    let systemImage: String?

    var body: some View {
        if let systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text(title)
        }
    }
}

/// A `NavigationLink` wearing `WNButton`'s chrome, so a push can sit beside a
/// button without reading as a plain text link. A push has to come from a real
/// link when the control lives in a safe-area accessory, where a
/// `navigationDestination(isPresented:)` is not reliably inside the stack's
/// own view tree.
struct WNButtonNavigationLink<Destination: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let title: LocalizedStringKey
    var systemImage: String?
    var emphasis = WNButton.Emphasis.primary
    var size = WNButton.Size.large
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            WNButtonTitle(title: title, systemImage: systemImage)
                .wnButtonContentColor(
                    emphasis,
                    size: size,
                    colorScheme: colorScheme,
                    isEnabled: isEnabled
                )
                .wnButtonLabelSizing(size)
        }
        .wnButtonStyle(emphasis, size: size)
        .wnButtonChrome(emphasis: emphasis)
        .controlSize(WNButton.Metrics.controlSize(for: size))
        .wnButtonSizing(size)
    }
}

private struct WNButtonChrome: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let borderShape: ButtonBorderShape
    let emphasis: WNButton.Emphasis

    func body(content: Content) -> some View {
        content
            .buttonBorderShape(borderShape)
            .wnButtonTint(emphasis, colorScheme: colorScheme)
    }
}

extension View {
    func wnButtonChrome(
        _ borderShape: ButtonBorderShape = .capsule,
        emphasis: WNButton.Emphasis = .primary
    ) -> some View {
        modifier(WNButtonChrome(borderShape: borderShape, emphasis: emphasis))
    }

    func wnAvatarActionButtonStyle() -> some View {
        wnSecondaryButtonStyle()
            .wnButtonChrome(emphasis: .secondary)
    }

    /// iOS 26 glass supplies its own material and vibrant label. A monochrome
    /// tint or an explicit foreground flattens it into a solid disc, so both are
    /// left to the system there and kept only for the hand-painted fallback and
    /// for the prominent fill, whose black/white is deliberate.
    @ViewBuilder
    func wnButtonTint(
        _ emphasis: WNButton.Emphasis,
        colorScheme: ColorScheme
    ) -> some View {
        if emphasis == .destructive {
            // Glass does not carry "this deletes your data"; the red does.
            tint(.red)
        } else if #available(iOS 26.0, *), emphasis == .secondary {
            self
        } else {
            tint(WNButton.Metrics.accent(for: colorScheme))
        }
    }

    @ViewBuilder
    func wnButtonContentColor(
        _ emphasis: WNButton.Emphasis,
        size: WNButton.Size,
        colorScheme: ColorScheme,
        isEnabled: Bool
    ) -> some View {
        if #available(iOS 26.0, *),
           emphasis == .secondary,
           WNButton.Metrics.drawsOwnSurface(emphasis: emphasis, size: size) {
            self
        } else {
            foregroundStyle(
                WNButton.Metrics.contentColor(
                    emphasis: emphasis,
                    colorScheme: colorScheme,
                    isEnabled: isEnabled
                )
            )
        }
    }

    @ViewBuilder
    func wnButtonStyle(
        _ emphasis: WNButton.Emphasis,
        size: WNButton.Size
    ) -> some View {
        if #available(iOS 26.0, *),
           !WNButton.Metrics.drawsOwnSurface(emphasis: emphasis, size: size) {
            self
        } else {
            switch emphasis {
            case .primary, .destructive:
                wnPrimaryButtonStyle()
            case .secondary:
                wnSecondaryButtonStyle()
            }
        }
    }

    @ViewBuilder
    func wnPrimaryButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func wnSecondaryButtonStyle(
        _ shape: WNSecondaryButtonStyle.Shape = .capsule
    ) -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(WNSecondaryButtonStyle(shape: shape))
        }
    }

    @ViewBuilder
    func wnButtonSizing(_ size: WNButton.Size = .large) -> some View {
        if #available(iOS 26.0, *), WNButton.Metrics.stretches(size) {
            buttonSizing(.flexible)
        } else {
            self
        }
    }

    @ViewBuilder
    func wnButtonLabelSizing(_ size: WNButton.Size = .large) -> some View {
        if #available(iOS 26.0, *) {
            self
        } else if WNButton.Metrics.stretches(size) {
            frame(maxWidth: .infinity, minHeight: WNButton.Metrics.fallbackLabelMinHeight)
        } else {
            self
        }
    }
}

#Preview("WNButton — Light") {
    VStack {
        WNButton(title: "Sign In", emphasis: .secondary) {}
        WNButton(title: "Sign Up") {}
        WNButton(title: "Add Profile", systemImage: "person.crop.circle.badge.plus") {}
        WNButton(title: "Signing Up…", isLoading: true) {}
        WNButton(title: "Sign Up") {}
            .disabled(true)
    }
    .safeAreaPadding(.horizontal)
}

#Preview("WNButton — Dark") {
    VStack {
        WNButton(title: "Sign In", emphasis: .secondary) {}
        WNButton(title: "Sign Up") {}
        WNButton(title: "Signing Up…", isLoading: true) {}
    }
    .safeAreaPadding(.horizontal)
    .preferredColorScheme(.dark)
}

#Preview("WNButton — Destructive") {
    VStack(spacing: 16) {
        WNButton(title: "Sign Out", emphasis: .destructive, size: .standard) {}
        WNButton(title: "Sign Out", emphasis: .destructive, size: .standard, isLoading: true) {}
        WNButton(title: "Sign Out", emphasis: .destructive, size: .standard) {}
            .disabled(true)
        WNButton(title: "Erase", emphasis: .destructive) {}
    }
    .safeAreaPadding(.horizontal)
}

#Preview("WNButton — Compact") {
    VStack(spacing: 24) {
        WNButton(title: "Edit", emphasis: .secondary, size: .compact) {}
        WNButton(title: "Done", size: .compact) {}
        WNButton(title: "Publishing…", size: .compact, isLoading: true) {}
        WNButton(title: "Edit", emphasis: .secondary, size: .compact) {}
            .disabled(true)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
}

#Preview("WN avatar action — Light") {
    VStack(spacing: 24) {
        Button("Add Photo") {}
            .wnAvatarActionButtonStyle()

        Menu("Change Photo") {
            Button("Choose from Photos") {}
        }
        .wnAvatarActionButtonStyle()

        Button("Add Photo") {}
            .wnAvatarActionButtonStyle()
            .disabled(true)
    }
}

#Preview("WN avatar action — Dark") {
    VStack(spacing: 24) {
        Button("Add Photo") {}
            .wnAvatarActionButtonStyle()

        Menu("Change Photo") {
            Button("Choose from Photos") {}
        }
        .wnAvatarActionButtonStyle()
    }
    .preferredColorScheme(.dark)
}

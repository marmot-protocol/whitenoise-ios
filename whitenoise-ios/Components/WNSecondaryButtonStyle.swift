import SwiftUI

struct WNSecondaryButtonStyle: ButtonStyle {
    nonisolated enum Surface: Equatable {
        case lifted
        case translucent
    }

    /// A text button is a pill; an icon-only button is a circle of the tap
    /// target's diameter, so the glyph is not stretched by the pill's padding.
    nonisolated enum Shape: Equatable {
        case capsule
        case circle
    }

    nonisolated enum Metrics {
        nonisolated struct Insets: Equatable {
            let horizontal: CGFloat
            let vertical: CGFloat
        }

        static let horizontalPadding: CGFloat = 20
        static let circleDiameter: CGFloat = 44
        static let shadowRadius: CGFloat = 6
        static let shadowOffsetY: CGFloat = 2
        static let pressFade = 0.7

        static func verticalPadding(for controlSize: ControlSize) -> CGFloat {
            controlSize == .extraLarge ? 15 : 10
        }

        /// The circle sizes itself from `circleDiameter` instead of padding, so
        /// its glyph stays centered whatever the label's intrinsic width is.
        static func insets(for shape: Shape, controlSize: ControlSize) -> Insets {
            switch shape {
            case .capsule:
                Insets(
                    horizontal: horizontalPadding,
                    vertical: verticalPadding(for: controlSize)
                )
            case .circle:
                Insets(horizontal: 0, vertical: 0)
            }
        }

        static func diameter(for shape: Shape, scaled: CGFloat) -> CGFloat? {
            shape == .circle ? scaled : nil
        }

        static func backgroundShape(for shape: Shape) -> AnyShape {
            switch shape {
            case .capsule:
                AnyShape(Capsule())
            case .circle:
                AnyShape(Circle())
            }
        }

        static func surface(for colorScheme: ColorScheme) -> Surface {
            colorScheme == .dark ? .translucent : .lifted
        }

        static func fill(for surface: Surface) -> AnyShapeStyle {
            switch surface {
            case .lifted: AnyShapeStyle(.background)
            case .translucent: AnyShapeStyle(.quaternary)
            }
        }

        static func shadowOpacity(for colorScheme: ColorScheme) -> Double {
            colorScheme == .dark ? 0 : 0.12
        }

        static func labelColor(isEnabled: Bool) -> Color {
            isEnabled ? .primary : .secondary
        }

        static func opacity(isPressed: Bool) -> Double {
            isPressed ? pressFade : 1
        }
    }

    var shape = Shape.capsule

    func makeBody(configuration: Configuration) -> some View {
        WNSecondaryButtonLabel(shape: shape, configuration: configuration)
    }
}

extension ButtonStyle where Self == WNSecondaryButtonStyle {
    static var wnSecondary: Self { WNSecondaryButtonStyle() }

    static var wnSecondaryCircle: Self { WNSecondaryButtonStyle(shape: .circle) }
}

private struct WNSecondaryButtonLabel: View {
    private typealias Metrics = WNSecondaryButtonStyle.Metrics

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    @ScaledMetric(relativeTo: .body) private var scaledDiameter = Metrics.circleDiameter

    let shape: WNSecondaryButtonStyle.Shape
    let configuration: WNSecondaryButtonStyle.Configuration

    var body: some View {
        let insets = Metrics.insets(for: shape, controlSize: controlSize)
        let diameter = Metrics.diameter(for: shape, scaled: scaledDiameter)
        let background = Metrics.backgroundShape(for: shape)

        return configuration.label
            .foregroundStyle(Metrics.labelColor(isEnabled: isEnabled))
            .padding(.horizontal, insets.horizontal)
            .padding(.vertical, insets.vertical)
            .frame(width: diameter, height: diameter)
            .frame(minHeight: scaledDiameter)
            .background {
                background
                    .fill(Metrics.fill(for: Metrics.surface(for: colorScheme)))
                    .shadow(
                        color: .black.opacity(Metrics.shadowOpacity(for: colorScheme)),
                        radius: Metrics.shadowRadius,
                        y: Metrics.shadowOffsetY
                    )
            }
            .contentShape(background)
            .opacity(Metrics.opacity(isPressed: configuration.isPressed))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview("WNSecondaryButtonStyle — Light") {
    VStack(spacing: 24) {
        Button("Sign In") {}
            .buttonStyle(.wnSecondary)

        Button("Add Photo") {}
            .buttonStyle(.wnSecondary)
            .disabled(true)

        Button("Back", systemImage: "chevron.backward") {}
            .labelStyle(.iconOnly)
            .buttonStyle(.wnSecondaryCircle)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
}

#Preview("WNSecondaryButtonStyle — Dark") {
    VStack(spacing: 24) {
        Button("Sign In") {}
            .buttonStyle(.wnSecondary)

        Button("Add Photo") {}
            .buttonStyle(.wnSecondary)
            .disabled(true)

        Button("Back", systemImage: "chevron.backward") {}
            .labelStyle(.iconOnly)
            .buttonStyle(.wnSecondaryCircle)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    .preferredColorScheme(.dark)
}

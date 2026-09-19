import SwiftUI
import UIKit

extension View {
    /// Uses iOS 26 Liquid Glass when available, with a material fallback for
    /// the iOS 18 support floor.
    @ViewBuilder
    func compatibleGlassEffect(
        cornerRadius: CGFloat,
        fallbackMaterial: Material = .regularMaterial
    ) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.clear.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            background(
                fallbackMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }

    /// Groups adjacent bottom-input glass so iOS 26 can composite and refract together.
    @ViewBuilder
    func bottomInputGlassContainer<Content: View>(
        spacing: CGFloat = BottomInputChromeLayout.rowSpacing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }

    /// Bottom input pill chrome shared by the chat list search field and composer-style controls.
    func compatibleInputCapsuleChrome(interactive: Bool = true) -> some View {
        modifier(CompatibleInputCapsuleChromeModifier(interactive: interactive))
    }

    func compatibleInputRoundedChrome(cornerRadius: CGFloat, interactive: Bool = true, usesRegularGlass: Bool = false) -> some View {
        modifier(CompatibleInputRoundedChromeModifier(cornerRadius: cornerRadius, interactive: interactive, usesRegularGlass: usesRegularGlass))
    }

    /// Circular companion to `compatibleInputCapsuleChrome()` for side actions.
    func compatibleInputCircleChrome(interactive: Bool = true, usesRegularGlass: Bool = false) -> some View {
        modifier(CompatibleInputCircleChromeModifier(interactive: interactive, usesRegularGlass: usesRegularGlass))
    }

    /// Applies Liquid Glass circle button behavior on iOS 26, press scale fallback earlier.
    @ViewBuilder
    func compatibleGlassCircleButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
                .buttonBorderShape(.circle)
        } else {
            buttonStyle(InputCirclePressButtonStyle())
        }
    }

    /// Circle chrome for side actions when not using `.buttonStyle(.glass)`.
    @ViewBuilder
    func legacyInputCircleChrome() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            compatibleInputCircleChrome()
        }
    }

    /// Lets scrolling content show through bottom Liquid Glass chrome on iOS 26.
    @ViewBuilder
    func compatibleBottomScrollEdgeEffect() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.automatic, for: .bottom)
        } else {
            self
        }
    }

    /// Uses a crisp boundary below top chrome instead of the default soft fade.
    @ViewBuilder
    func compatibleTopScrollEdgeEffect() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self
        }
    }

    /// Uses the platform's context-sensitive treatment beneath top navigation chrome.
    @ViewBuilder
    func compatibleAutomaticTopScrollEdgeEffect() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.automatic, for: .top)
        } else {
            self
        }
    }

    /// Extends the native top scroll-edge treatment through inset content on iOS 26.
    @ViewBuilder
    func compatibleTopSafeAreaBar<BarContent: View>(
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> BarContent
    ) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: spacing, content: content)
        } else {
            safeAreaInset(edge: .top, spacing: spacing, content: content)
        }
    }

    /// Keeps custom bottom input surfaces from adding a scroll-edge fade on iOS 26.
    @ViewBuilder
    func compatibleBottomScrollEdgeEffectHidden() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .bottom)
        } else {
            self
        }
    }
}

private struct CompatibleInputRoundedChromeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let interactive: Bool
    let usesRegularGlass: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(inputGlass(for: colorScheme, interactive: interactive, usesRegularGlass: usesRegularGlass), in: shape)
                .compatibleInputLightStroke(in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

private struct CompatibleInputCapsuleChromeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let interactive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    inputGlass(for: colorScheme, interactive: interactive),
                    in: Capsule(style: .continuous)
                )
                .compatibleInputLightStroke(in: Capsule(style: .continuous))
        } else {
            content.background(.regularMaterial, in: Capsule(style: .continuous))
        }
    }
}

private struct CompatibleInputCircleChromeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let interactive: Bool
    let usesRegularGlass: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    inputGlass(for: colorScheme, interactive: interactive, usesRegularGlass: usesRegularGlass),
                    in: Circle()
                )
                .compatibleInputLightStroke(in: Circle())
        } else {
            content.background(.regularMaterial, in: Circle())
        }
    }
}

private extension View {
    @ViewBuilder
    func compatibleInputLightStroke<S: InsettableShape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            modifier(CompatibleInputLightStrokeModifier(shape: shape))
        } else {
            self
        }
    }
}

private struct CompatibleInputLightStrokeModifier<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let shape: S

    func body(content: Content) -> some View {
        content.overlay {
            if colorScheme == .light {
                shape.strokeBorder(
                    Color.primary.opacity(BottomInputChromeLayout.lightModeInputStrokeOpacity),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            }
        }
    }
}

@available(iOS 26.0, *)
private func inputGlass(for colorScheme: ColorScheme, interactive: Bool, usesRegularGlass: Bool = false) -> Glass {
    let base: Glass = usesRegularGlass || colorScheme == .light ? .regular : .clear
    return interactive ? base.interactive() : base
}

struct InputCirclePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.08 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

struct FullScreenConfirmationDialog: View {
    let title: String
    let message: String
    let systemImage: String
    let destructiveTitle: String
    var cancelTitle: String = "Cancel"
    var onConfirm: () -> Void
    var onCancel: () -> Void

    @ScaledMetric(relativeTo: .largeTitle)
    private var heroIconSize: CGFloat = 44
    @ScaledMetric(relativeTo: .largeTitle)
    private var heroBadgeSize: CGFloat = 76

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 32)

                VStack(spacing: 18) {
                    Image(systemName: systemImage)
                        .font(.system(size: heroIconSize, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: heroBadgeSize, height: heroBadgeSize)
                        .background(Color.red.opacity(0.12), in: Circle())

                    VStack(spacing: 10) {
                        Text(title)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.primary)

                        Text(message)
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 28)

                Spacer(minLength: 32)

                VStack(spacing: 12) {
                    Button(role: .destructive, action: onConfirm) {
                        Text(destructiveTitle)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Button(role: .cancel, action: onCancel) {
                        Text(cancelTitle)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }
}

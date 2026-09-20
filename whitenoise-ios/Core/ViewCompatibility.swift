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
            glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
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

    /// Regular glass is the app's control material in both appearances.
    @ViewBuilder
    func compatibleControlChrome<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    func compatibleInputCapsuleChrome(interactive: Bool = true) -> some View {
        compatibleControlChrome(in: Capsule(), interactive: interactive)
    }

    func compatibleInputRoundedChrome(cornerRadius: CGFloat, interactive: Bool = true) -> some View {
        compatibleControlChrome(
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            interactive: interactive
        )
    }

    func compatibleInputCircleChrome(interactive: Bool = true) -> some View {
        compatibleControlChrome(in: Circle(), interactive: interactive)
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

struct InputCirclePressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 1.08 : 1.0)
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
                            .wnButtonLabelSizing(.large)
                    }
                    .wnPrimaryButtonStyle()
                    .wnButtonChrome(emphasis: .destructive)
                    .controlSize(.extraLarge)
                    .wnButtonSizing(.large)

                    Button(role: .cancel, action: onCancel) {
                        Text(cancelTitle)
                            .font(.headline)
                            .wnButtonLabelSizing(.large)
                    }
                    .wnSecondaryButtonStyle()
                    .controlSize(.extraLarge)
                    .wnButtonSizing(.large)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }
}

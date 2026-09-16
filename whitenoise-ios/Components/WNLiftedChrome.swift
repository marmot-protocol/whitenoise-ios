import SwiftUI

/// The non-button companion to `wnSecondaryButtonStyle`: same lifted surface,
/// for labels that float over media and cannot carry a `ButtonStyle`.
extension View {
    func wnLiftedChrome<S: Shape>(in shape: S) -> some View {
        modifier(WNLiftedChromeModifier(shape: shape))
    }
}

private struct WNLiftedChromeModifier<S: Shape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background {
                shape
                    .fill(WNSecondaryButtonStyle.Metrics.fill(
                        for: WNSecondaryButtonStyle.Metrics.surface(for: colorScheme)
                    ))
                    .shadow(
                        color: .black.opacity(
                            WNSecondaryButtonStyle.Metrics.shadowOpacity(for: colorScheme)
                        ),
                        radius: WNSecondaryButtonStyle.Metrics.shadowRadius,
                        y: WNSecondaryButtonStyle.Metrics.shadowOffsetY
                    )
            }
        }
    }
}

#Preview("WNLiftedChrome — Light") {
    Text("2 of 5")
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .wnLiftedChrome(in: .capsule)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { WNMediaSurface() }
}

#Preview("WNLiftedChrome — Dark") {
    Text("2 of 5")
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .wnLiftedChrome(in: .capsule)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { WNMediaSurface() }
        .preferredColorScheme(.dark)
}

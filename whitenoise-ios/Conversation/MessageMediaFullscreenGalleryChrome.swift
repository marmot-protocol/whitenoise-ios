import SwiftUI

struct MessageMediaFullscreenGalleryChrome: View {
    let pageCountLabel: String?
    let controlState: MediaViewerControlState
    let onClose: () -> Void
    let onSave: () -> Void
    let onShare: () -> Void
    let onForward: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                WNIconButton(title: "Close", systemImage: "xmark", action: onClose)

                Spacer(minLength: 0)

                if let pageCountLabel {
                    Text(pageCountLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .wnLiftedChrome(in: .capsule)
                }

                Spacer(minLength: 0)

                MessageMediaGalleryMoreMenu(canSave: controlState.canSave, onSave: onSave)
            }

            Spacer(minLength: 0)

            HStack {
                WNIconButton(
                    title: "Share",
                    systemImage: "square.and.arrow.up",
                    action: onShare
                )
                .disabled(!controlState.canShare)

                Spacer(minLength: 0)

                WNIconButton(
                    title: "Forward",
                    systemImage: "arrowshape.turn.up.right",
                    action: onForward
                )
                .disabled(!controlState.canForward)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// A `Menu` label inherits the accent tint, which is why an unstyled ellipsis
/// renders blue; the glyph colour has to be pinned on both the label and the menu.
private struct MessageMediaGalleryMoreMenu: View {
    @ScaledMetric(relativeTo: .body)
    private var diameter: CGFloat = WNSecondaryButtonStyle.Metrics.circleDiameter

    let canSave: Bool
    let onSave: () -> Void

    var body: some View {
        Menu {
            Button("Save", systemImage: "square.and.arrow.down", action: onSave)
                .disabled(!canSave)
        } label: {
            Label("More", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .imageScale(.large)
                .foregroundStyle(.primary)
                .frame(width: diameter, height: diameter)
                .contentShape(.circle)
                .wnLiftedChrome(in: .circle)
        }
        .tint(Color.primary)
        .accessibilityLabel("More")
    }
}

#Preview("Gallery chrome — Light") {
    MessageMediaFullscreenGalleryChrome(
        pageCountLabel: "2 of 5",
        controlState: MediaViewerControlState(hasPreparedMedia: true, hasForwardingContext: true),
        onClose: {},
        onSave: {},
        onShare: {},
        onForward: {}
    )
    .background { WNMediaSurface().ignoresSafeArea() }
}

#Preview("Gallery chrome — Dark, media still loading") {
    MessageMediaFullscreenGalleryChrome(
        pageCountLabel: nil,
        controlState: MediaViewerControlState(hasPreparedMedia: false, hasForwardingContext: false),
        onClose: {},
        onSave: {},
        onShare: {},
        onForward: {}
    )
    .background { WNMediaSurface().ignoresSafeArea() }
    .preferredColorScheme(.dark)
}

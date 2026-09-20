import SwiftUI

struct MessageMediaFullscreenGalleryChrome: View {
    let pageCountLabel: String?
    let controlState: MediaViewerControlState
    let onClose: () -> Void
    let onSave: () -> Void
    let onShare: () -> Void
    let onForward: () -> Void
    let onGoToMessage: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                MessageMediaGalleryButton(title: "Close", systemImage: "xmark", action: onClose)

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

                MessageMediaGalleryMoreMenu(
                    canSave: controlState.canSave,
                    canGoToMessage: controlState.canGoToMessage,
                    onSave: onSave,
                    onGoToMessage: onGoToMessage
                )
            }

            Spacer(minLength: 0)

            HStack {
                MessageMediaGalleryButton(
                    title: "Share",
                    systemImage: "square.and.arrow.up",
                    action: onShare
                )
                .disabled(!controlState.canShare)

                Spacer(minLength: 0)

                MessageMediaGalleryButton(
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
private struct MessageMediaGalleryControlLabel: View {
    @ScaledMetric(relativeTo: .body)
    private var diameter: CGFloat = WNSecondaryButtonStyle.Metrics.circleDiameter
    @Environment(\.isEnabled) private var isEnabled

    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .imageScale(.large)
            .foregroundStyle(isEnabled ? .primary : .secondary)
            .frame(width: diameter, height: diameter)
            .contentShape(.circle)
            .wnLiftedChrome(in: .circle)
    }
}

private struct MessageMediaGalleryButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MessageMediaGalleryControlLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }
}

private struct MessageMediaGalleryMoreMenu: View {

    let canSave: Bool
    let canGoToMessage: Bool
    let onSave: () -> Void
    let onGoToMessage: () -> Void

    var body: some View {
        Menu {
            Button("Save", systemImage: "square.and.arrow.down", action: onSave)
                .disabled(!canSave)

            if canGoToMessage {
                Button("Go to Message", systemImage: "bubble.left", action: onGoToMessage)
            }
        } label: {
            MessageMediaGalleryControlLabel(title: "More", systemImage: "ellipsis")
        }
        .buttonStyle(.plain)
        .tint(Color.primary)
        .accessibilityLabel("More")
    }
}

#Preview("Gallery chrome — Light") {
    MessageMediaFullscreenGalleryChrome(
        pageCountLabel: "2 of 5",
        controlState: MediaViewerControlState(
            hasPreparedMedia: true,
            hasForwardingContext: true,
            hasSourceMessage: true
        ),
        onClose: {},
        onSave: {},
        onShare: {},
        onForward: {},
        onGoToMessage: {}
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
        onForward: {},
        onGoToMessage: {}
    )
    .background { WNMediaSurface().ignoresSafeArea() }
    .preferredColorScheme(.dark)
}

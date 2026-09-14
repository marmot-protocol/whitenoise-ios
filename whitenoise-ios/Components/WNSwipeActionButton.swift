import SwiftUI

/// A swipe control that shows only its glyph.
///
/// The label is an `Image` rather than a `Label`, because SwiftUI hands
/// whatever `Text` it finds to the swipe slot as the action title, and a titled
/// action is drawn as a wide labelled pill instead of the round glyph button
/// the design asks for. `title` therefore reaches VoiceOver and nothing else —
/// it is the only name this control has, so it must never be omitted.
///
/// iOS 26 sizes and rounds the slot around the glyph on its own. iOS 18 fills
/// the whole row height with the tint and discards any shape drawn behind the
/// label, so there the circle is baked into the image by `WNSwipeActionBadge`
/// and the slot itself is filled with the row background — unless that render
/// fails, when the slot has to carry the tint instead.
struct WNSwipeActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body)
    private var diameter: CGFloat = WNSwipeActionBadgeMetrics.diameter

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(action: action) {
                Image(systemName: systemImage)
            }
            .tint(tint)
            .accessibilityLabel(title)
        } else {
            legacyButton
        }
    }

    /// One render drives both the label and the slot behind it, so a failed
    /// badge does not leave a white-on-white glyph in the slot.
    private var legacyButton: some View {
        let badge = WNSwipeActionBadge.image(
            systemImage: systemImage,
            tint: tint,
            diameter: diameter,
            colorScheme: colorScheme
        )
        return Button(action: action) {
            if let badge {
                Image(uiImage: badge)
            } else {
                Image(systemName: systemImage)
            }
        }
        .tint(WNSwipeActionBadge.slotTint(tint: tint, hasBadge: badge != nil))
        .accessibilityLabel(title)
    }
}

#Preview("WNSwipeActionButton — Light") {
    WNSwipeActionButtonPreview()
}

#Preview("WNSwipeActionButton — Dark") {
    WNSwipeActionButtonPreview()
        .preferredColorScheme(.dark)
}

private struct WNSwipeActionButtonPreview: View {
    private struct Sample: Identifiable {
        let id = UUID()
        let name: String
        let glyph: String
        let tint: Color
    }

    private let samples: [Sample] = [
        Sample(name: "Mark as read", glyph: "message.fill", tint: .blue),
        Sample(name: "Pin", glyph: "pin.fill", tint: .orange),
        Sample(name: "Mute", glyph: "bell.slash.fill", tint: .indigo),
        Sample(name: "Archive", glyph: "archivebox.fill", tint: .gray),
        Sample(name: "Delete", glyph: "trash.fill", tint: .red),
    ]

    var body: some View {
        List(samples) { sample in
            Text("Swipe \(sample.name)")
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing) {
                    WNSwipeActionButton(
                        title: sample.name,
                        systemImage: sample.glyph,
                        tint: sample.tint
                    ) {}
                }
        }
        .listStyle(.plain)
    }
}

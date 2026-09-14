import SwiftUI
import UIKit

/// Draws a swipe glyph onto a filled circle for the iOS 18 support floor.
///
/// SwiftUI flattens a swipe button into a `UIContextualAction`, which carries
/// only a title, an image, and a background colour — a shape drawn behind the
/// label is discarded on the way. So the circle has to live inside the image
/// itself, and the slot's own fill is set to the row background so that only
/// the circle reads as a button. iOS 26 rounds the slot natively and needs
/// none of this.
///
/// The renders are cached because a swipe rebuilds its buttons on every pan and
/// the inputs come from a fixed set of ten actions.
@MainActor
enum WNSwipeActionBadge {
    private struct Key: Hashable {
        let systemImage: String
        let tint: Color
        let diameter: CGFloat
        let colorScheme: ColorScheme
    }

    private static var cache: [Key: UIImage] = [:]

    static func image(
        systemImage: String,
        tint: Color,
        diameter: CGFloat,
        colorScheme: ColorScheme
    ) -> UIImage? {
        let key = Key(
            systemImage: systemImage,
            tint: tint,
            diameter: diameter,
            colorScheme: colorScheme
        )
        if let cached = cache[key] {
            return cached
        }

        let renderer = ImageRenderer(
            content: Badge(systemImage: systemImage, tint: tint, diameter: diameter)
                .environment(\.colorScheme, colorScheme)
        )
        renderer.scale = UITraitCollection.current.displayScale
        // A template image would be repainted flat white by UIKit, erasing the
        // tint the circle exists to carry.
        guard let image = renderer.uiImage?.withRenderingMode(.alwaysOriginal) else {
            return nil
        }
        cache[key] = image
        return image
    }

    /// The baked circle is the button, so the slot behind it drops away into
    /// the row. Without a render there is only a template glyph, which UIKit
    /// repaints flat white — that needs the tint behind it to stay visible.
    static func slotTint(tint: Color, hasBadge: Bool) -> Color {
        hasBadge ? Color(.systemBackground) : tint
    }

    private struct Badge: View {
        let systemImage: String
        let tint: Color
        let diameter: CGFloat

        var body: some View {
            Image(systemName: systemImage)
                // Geometry inside a rasterised badge, not type: the diameter it
                // scales from already tracks Dynamic Type.
                .font(.system(size: diameter * WNSwipeActionBadgeMetrics.glyphRatio))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(tint, in: .circle)
        }
    }
}

nonisolated enum WNSwipeActionBadgeMetrics {
    static let diameter: CGFloat = 40
    static let glyphRatio: CGFloat = 0.44
}

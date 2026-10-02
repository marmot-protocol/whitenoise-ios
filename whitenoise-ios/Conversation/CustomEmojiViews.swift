import SwiftUI
import UIKit

extension EnvironmentValues {
    /// The conversation's custom emoji image store; nil outside a conversation.
    @Entry var customEmojiStore: ConversationCustomEmojiStore? = nil
    /// Inline custom emoji for the message body being rendered.
    @Entry var customEmojiInline: CustomEmojiInlineContext = .none
}

/// The resolved shortcodes of one message body and the images loaded so far.
/// A resolvable shortcode without an image renders as its literal text.
struct CustomEmojiInlineContext: Equatable {
    var resolvable: Set<CustomEmojiShortcode> = []
    var images: [CustomEmojiShortcode: UIImage] = [:]
    var baselineOffset: CGFloat = 0

    static let none = Self()

    var isEmpty: Bool { resolvable.isEmpty }
}

/// Inline emoji metrics. The image tracks the body text size, so it scales
/// with Dynamic Type through the caller's `@ScaledMetric`.
nonisolated enum CustomEmojiInlineMetrics {
    static let bodyPointSize: CGFloat = 20
    static let bodyBaselineOffset: CGFloat = -4

    static func pixelSize(pointSize: CGFloat, scale: CGFloat) -> Int {
        max(1, Int(ceil(max(1, pointSize) * max(1, scale))))
    }
}

enum CustomEmojiTextComposer {
    /// `attributed` with each resolvable `:shortcode:` replaced by its image.
    /// The image carries the shortcode name as its accessibility label, so
    /// VoiceOver reads the name in place of the picture.
    static func text(_ attributed: AttributedString, context: CustomEmojiInlineContext) -> Text {
        guard !context.isEmpty else { return Text(attributed) }
        let segments = CustomEmojiText.segments(of: attributed, resolvable: context.resolvable)
        guard segments.count > 1 || segments.first.map(isEmoji) == true else { return Text(attributed) }
        var interpolation = LocalizedStringKey.StringInterpolation(
            literalCapacity: 0,
            interpolationCount: segments.count
        )
        for segment in segments {
            switch segment {
            case .text(let run):
                interpolation.appendInterpolation(Text(run))
            case .emoji(let shortcode, let original):
                if let image = context.images[shortcode], let cgImage = image.cgImage {
                    interpolation.appendInterpolation(
                        Text(Image(cgImage, scale: image.scale, orientation: .up,
                                   label: Text(verbatim: shortcode.name)))
                            .baselineOffset(context.baselineOffset)
                    )
                } else {
                    interpolation.appendInterpolation(Text(original))
                }
            }
        }
        return Text(LocalizedStringKey(stringInterpolation: interpolation), tableName: "CustomEmojiInlineText")
    }

    private static func isEmoji(_ segment: CustomEmojiText.AttributedSegment) -> Bool {
        if case .emoji = segment { return true }
        return false
    }
}

/// Text that draws the environment's inline custom emoji.
struct CustomEmojiAwareText: View {
    @Environment(\.customEmojiInline) private var customEmoji
    let text: AttributedString

    init(_ text: AttributedString) {
        self.text = text
    }

    var body: some View {
        CustomEmojiTextComposer.text(text, context: customEmoji)
    }
}

/// Loads a message row's inline emoji images while the row is visible.
struct CustomEmojiInlineLoader: ViewModifier {
    @Environment(\.customEmojiStore) private var store
    @Environment(\.timelineRowIsVisible) private var isVisible
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .body) private var pointSize = CustomEmojiInlineMetrics.bodyPointSize
    @ScaledMetric(relativeTo: .body) private var baselineOffset = CustomEmojiInlineMetrics.bodyBaselineOffset

    let resolution: CustomEmojiRowResolution
    /// Images keyed by scope, row-scoped attachment id and pixel size. Only
    /// keys for the current scope are shown, so an account switch, runtime
    /// restart or chat change withholds old images immediately.
    @State private var images: [CustomEmojiImageKey: UIImage] = [:]

    private struct TaskID: Equatable {
        let scope: CustomEmojiScope?
        let itemIDs: [String]
        let isVisible: Bool
        let pixelSize: Int
        let policyRevision: String
    }

    func body(content: Content) -> some View {
        let scope = store?.currentScope
        let size = pixelSize
        return content
            .environment(\.customEmojiInline, context(scope: scope, pixelSize: size))
            .task(id: TaskID(
                scope: scope,
                itemIDs: resolution.inline.values.map(\.id).sorted(),
                isVisible: isVisible,
                pixelSize: size,
                policyRevision: MediaAutoDownloadStore.shared.attachmentPolicyRevision
            )) {
                images = images.filter { $0.key.scope == scope }
                guard isVisible, let store, scope != nil, !resolution.isEmpty else { return }
                let revision = MediaAutoDownloadStore.shared.attachmentPolicyRevision
                let unique = Dictionary(resolution.inline.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for (_, item) in unique.sorted(by: { $0.key < $1.key }) {
                    guard let loaded = await store.inlineImage(for: item, pixelSize: size,
                        scale: displayScale, policyRevision: revision),
                          !Task.isCancelled, loaded.key.scope == store.currentScope else { continue }
                    images[loaded.key] = loaded.image
                }
            }
    }

    private var pixelSize: Int {
        CustomEmojiInlineMetrics.pixelSize(pointSize: pointSize, scale: displayScale)
    }

    private func context(scope: CustomEmojiScope?, pixelSize: Int) -> CustomEmojiInlineContext {
        guard !resolution.isEmpty else { return .none }
        return CustomEmojiInlineContext(
            resolvable: resolution.shortcodes,
            images: CustomEmojiInlinePresentation.images(for: resolution, loaded: images, scope: scope, pixelSize: pixelSize),
            baselineOffset: baselineOffset
        )
    }
}

/// A reaction's label. MDK 0.12.0 exposes no host-managed slot for kind-7
/// reaction images, so a `:shortcode:` reaction shows its sanitized text and
/// VoiceOver reads the shortcode name.
struct CustomEmojiReactionLabel: View {
    let emoji: String

    var body: some View {
        Text(ContentSanitizer.reactionEmoji(emoji))
            .accessibilityLabel(Text(verbatim: CustomEmojiShortcode.spokenReaction(emoji)))
    }
}

#Preview("Inline custom emoji") {
    let party = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
        UIColor.systemOrange.setFill()
        context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 20, height: 20))
    }
    let wave = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
        UIColor.systemTeal.setFill()
        context.cgContext.fill(CGRect(x: 2, y: 2, width: 16, height: 16))
    }
    let partyCode = CustomEmojiShortcode("party")!
    let waveCode = CustomEmojiShortcode("wave")!
    let loading = CustomEmojiShortcode("loading")!
    let context = CustomEmojiInlineContext(
        resolvable: [partyCode, waveCode, loading],
        images: [partyCode: party, waveCode: wave],
        baselineOffset: CustomEmojiInlineMetrics.bodyBaselineOffset
    )
    return VStack(alignment: .leading, spacing: 12) {
        CustomEmojiTextComposer.text(AttributedString("Hi :party: everyone :wave: and :loading: and :unknown:"), context: context)
        CustomEmojiTextComposer.text(AttributedString("مرحبا :party: بالجميع"), context: context)
            .environment(\.layoutDirection, .rightToLeft)
        CustomEmojiTextComposer.text(AttributedString("Large :party:"), context: context)
            .font(.title)
    }
    .font(.body)
    .padding()
}

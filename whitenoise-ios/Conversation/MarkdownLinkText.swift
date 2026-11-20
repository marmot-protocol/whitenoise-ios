import SwiftUI

struct MarkdownLinkText: View {
    @Environment(\.copyMessageLink) private var copyMessageLink
    @Environment(\.customEmojiInline) private var customEmoji

    @Environment(\.messageTextIsOutgoing) private var outgoing

    let text: AttributedString
    private let segments: [MessageLinkSegment]

    init(_ text: AttributedString) {
        self.text = text
        segments = MessageLinkSegment.segments(of: text)
    }

    private var hasCopyableLinks: Bool {
        segments.contains { $0.target != nil }
    }

    var body: some View {
        if let copyMessageLink, hasCopyableLinks {
            Self.composedText(segments, customEmoji: customEmoji)
                .textRenderer(renderer)
                .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                    GeometryReader { proxy in
                        let regions = Self.hitRegions(in: layouts, proxy: proxy)
                        ForEach(regions.indices, id: \.self) { index in
                            MessageLinkHitTarget(region: regions[index], copyMessageLink: copyMessageLink)
                        }
                    }
                }
        } else {
            TimelineTextMark.text(text, emoji: customEmoji)
                .textRenderer(renderer)
        }
    }

    private var renderer: TimelineTextRenderer {
        TimelineTextRenderer(mentionColor: MessageBubblePalette.foreground(isFromMe: outgoing).opacity(outgoing ? 0.2 : 0.1))
    }

    private static func composedText(_ segments: [MessageLinkSegment], customEmoji: CustomEmojiInlineContext) -> Text {
        var interpolation = LocalizedStringKey.StringInterpolation(
            literalCapacity: 0,
            interpolationCount: segments.count
        )
        for segment in segments {
            if let target = segment.target {
                interpolation.appendInterpolation(
                    TimelineTextMark.text(segment.text, emoji: customEmoji)
                        .customAttribute(MessageLinkTextAttribute(target: target))
                )
            } else {
                interpolation.appendInterpolation(TimelineTextMark.text(segment.text, emoji: customEmoji))
            }
        }
        return Text(LocalizedStringKey(stringInterpolation: interpolation), tableName: "MarkdownLinkText")
    }

    private static func hitRegions(
        in layouts: Text.LayoutKey.Value,
        proxy: GeometryProxy
    ) -> [MessageLinkHitRegion] {
        layouts.flatMap { anchored in
            let origin = proxy[anchored.origin]
            let runs = anchored.layout.flatMap { line in
                line.map { run in
                    (
                        url: run[MessageLinkTextAttribute.self]?.target.url,
                        rect: run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y)
                    )
                }
            }
            return MessageLinkHitRegion.regions(from: runs)
        }
    }
}

private struct MessageLinkTextAttribute: TextAttribute {
    let target: MessageLinkTarget
}

private struct MessageLinkHitTarget: View {
    @Environment(\.openURL) private var openURL

    let region: MessageLinkHitRegion
    let copyMessageLink: MessageLinkCopyAction

    var body: some View {
        Color.clear
            .frame(width: region.rect.width, height: region.rect.height)
            .contentShape(.rect)
            .onTapGesture { openURL(region.target.url) }
            .gesture(MessageLinkCopyHold { copyMessageLink(region.target) })
            .accessibilityHidden(true)
            .position(x: region.rect.midX, y: region.rect.midY)
    }
}

/// The row hold waits for this more specific action when the touch lands on a link.
struct MessageLinkCopyHold: UIGestureRecognizerRepresentable {
    final class Recognizer: UILongPressGestureRecognizer {}
    let copy: () -> Void

    func makeUIGestureRecognizer(context: Context) -> Recognizer { Recognizer() }
    func handleUIGestureRecognizerAction(_ recognizer: Recognizer, context: Context) {
        if recognizer.state == .began { copy() }
    }
}

#Preview {
    var link = AttributedString("example.com")
    link.link = URL(string: "https://example.com")
    return MarkdownLinkText(AttributedString("Read ") + link + AttributedString(" today"))
        .environment(\.copyMessageLink, MessageLinkCopyAction { _ in })
        .padding()
}

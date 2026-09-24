import SwiftUI

struct MarkdownLinkText: View {
    @Environment(\.copyMessageLink) private var copyMessageLink

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
            Self.composedText(segments)
                .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                    GeometryReader { proxy in
                        let regions = Self.hitRegions(in: layouts, proxy: proxy)
                        ForEach(regions.indices, id: \.self) { index in
                            MessageLinkHitTarget(region: regions[index], copyMessageLink: copyMessageLink)
                        }
                    }
                }
        } else {
            Text(text)
        }
    }

    private static func composedText(_ segments: [MessageLinkSegment]) -> Text {
        var interpolation = LocalizedStringKey.StringInterpolation(
            literalCapacity: 0,
            interpolationCount: segments.count
        )
        for segment in segments {
            if let target = segment.target {
                interpolation.appendInterpolation(
                    Text(segment.text).customAttribute(MessageLinkTextAttribute(target: target))
                )
            } else {
                interpolation.appendInterpolation(Text(segment.text))
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
            .onLongPressGesture { copyMessageLink(region.target) }
            .accessibilityHidden(true)
            .position(x: region.rect.midX, y: region.rect.midY)
    }
}

#Preview {
    var link = AttributedString("example.com")
    link.link = URL(string: "https://example.com")
    return MarkdownLinkText(AttributedString("Read ") + link + AttributedString(" today"))
        .environment(\.copyMessageLink, MessageLinkCopyAction { _ in })
        .padding()
}

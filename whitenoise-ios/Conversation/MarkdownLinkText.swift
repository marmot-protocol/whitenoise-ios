import SwiftUI

struct MarkdownLinkText: View {
    @Environment(\.copyMessageLink) private var copyMessageLink
    @Environment(\.customEmojiInline) private var customEmoji
    let text: AttributedString
    private let leadingSymbolName: String?

    init(_ text: AttributedString, leadingSymbolName: String? = nil) {
        self.text = text
        self.leadingSymbolName = leadingSymbolName
    }

    private var hasTimestamps: Bool {
        text.runs.contains { $0[MarkdownTimestampAttribute.self] != nil }
    }

    var body: some View {
        if hasTimestamps {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                interactiveText(now: context.date)
            }
        } else if copyMessageLink != nil || leadingSymbolName != nil {
            interactiveText(now: .now)
        } else {
            CustomEmojiTextComposer.text(text, context: customEmoji)
        }
    }

    private func interactiveText(now: Date) -> some View {
        composedText(now: now)
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { proxy in
                    let runs = layouts.flatMap { anchored in
                        let origin = proxy[anchored.origin]
                        return anchored.layout.flatMap { line in
                            line.compactMap { run -> MarkdownInlineHitRegion? in
                                guard let attribute = run[MarkdownInlineTextAttribute.self] else { return nil }
                                return MarkdownInlineHitRegion(
                                    attribute: attribute,
                                    rect: run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y)
                                )
                            }
                        }
                    }
                    let links = MessageLinkHitRegion.regions(from: runs.filter {
                        $0.attribute.timestamp == nil
                    }.map { (url: $0.attribute.url, rect: $0.rect) })
                    let regions = runs.filter { $0.attribute.timestamp != nil } + links.map {
                        MarkdownInlineHitRegion(attribute: MarkdownInlineTextAttribute(
                            id: 0, url: $0.target.url, timestamp: nil, clock: false), rect: $0.rect)
                    }
                    ForEach(regions) { region in
                        MarkdownInlineHitTarget(region: region, copyMessageLink: copyMessageLink)
                    }
                }
            }
    }

    private func composedText(now: Date) -> Text {
        var interpolation = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: text.runs.count)
        if let leadingSymbolName {
            interpolation.appendInterpolation(Text(Image(systemName: leadingSymbolName)) + Text(verbatim: " "))
        }
        for (index, run) in text.runs.enumerated() {
            var source = AttributedString(text[run.range])
            let target = run.link.flatMap(MessageLinkTarget.init(url:))
            if let timestamp = run[MarkdownTimestampAttribute.self] {
                let attribute = MarkdownInlineTextAttribute(id: index, url: run.link, timestamp: timestamp, clock: false)
                let clock = Text(Image(systemName: "clock"))
                    .font(run.font)
                    .customAttribute(MarkdownInlineTextAttribute(id: index, url: nil, timestamp: timestamp, clock: true))
                interpolation.appendInterpolation(clock)
                source.replaceSubrange(source.startIndex..<source.endIndex,
                    with: AttributedString(" " + timestamp.label(now: now), attributes: run.attributes))
                interpolation.appendInterpolation(Text(source).customAttribute(attribute))
            } else {
                let label = CustomEmojiTextComposer.text(source, context: customEmoji)
                if let target {
                    interpolation.appendInterpolation(label.customAttribute(
                        MarkdownInlineTextAttribute(id: index, url: target.url, timestamp: nil, clock: false)))
                } else {
                    interpolation.appendInterpolation(label)
                }
            }
        }
        return Text(LocalizedStringKey(stringInterpolation: interpolation), tableName: "MarkdownLinkText")
    }
}

private struct MarkdownInlineTextAttribute: TextAttribute, Hashable {
    let id: Int
    let url: URL?
    let timestamp: MarkdownTimestamp?
    let clock: Bool
}

private struct MarkdownInlineHitRegion: Identifiable {
    struct ID: Hashable {
        let attribute: MarkdownInlineTextAttribute
        let x: CGFloat
        let y: CGFloat
    }

    let attribute: MarkdownInlineTextAttribute
    let rect: CGRect
    var id: ID { ID(attribute: attribute, x: rect.minX, y: rect.minY) }
}

private struct MarkdownInlineHitTarget: View {
    @Environment(\.openURL) private var openURL
    @State private var isPresented = false
    let region: MarkdownInlineHitRegion
    let copyMessageLink: MessageLinkCopyAction?

    var body: some View {
        Color.clear
            .frame(width: region.rect.width, height: region.rect.height)
            .contentShape(.rect)
            .onTapGesture {
                if let url = region.attribute.url {
                    openURL(url)
                } else if region.attribute.timestamp != nil {
                    isPresented = true
                }
            }
            .onLongPressGesture {
                if let url = region.attribute.url, let target = MessageLinkTarget(url: url) { copyMessageLink?(target) }
            }
            .onHover { hovering in
                if region.attribute.timestamp != nil { isPresented = hovering }
            }
            .popover(isPresented: $isPresented) {
                if let timestamp = region.attribute.timestamp {
                    Text(verbatim: timestamp.disclosure())
                        .textSelection(.enabled)
                        .padding()
                }
            }
            .accessibilityHidden(!region.attribute.clock)
            .accessibilityLabel(Text(verbatim: region.attribute.timestamp?.disclosure() ?? ""))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { isPresented = true }
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

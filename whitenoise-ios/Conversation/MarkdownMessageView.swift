import SwiftUI

extension EnvironmentValues {
    @Entry var timelineSearchQuery: String?
    @Entry var messageTextIsOutgoing = false
}

extension AttributedString {
    /// Apply the mark after Markdown parsing so links, emphasis and timestamp attributes survive.
    func highlightingTimelineMatches(_ query: String?) -> Self {
        guard let query, !query.isEmpty else { return self }
        var result = self
        var cursor = result.startIndex
        while cursor < result.endIndex,
              let match = result[cursor...].range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
              match.upperBound > cursor {
            result[match][TimelineMatchAttribute.self] = true
            result[match].foregroundColor = .black
            cursor = match.upperBound
        }
        return result
    }
}

private enum TimelineMatchAttribute: AttributedStringKey {
    typealias Value = Bool
    static let name = "WhiteNoise.timelineSearchMatch"
}

enum TimelineTextMark: TextAttribute {
    case mention, search

    static func text(_ value: AttributedString, emoji: CustomEmojiInlineContext = .none) -> Text {
        guard value.runs.contains(where: { $0[TimelineMatchAttribute.self] == true || $0[MarkdownMentionAttribute.self] == true }) else {
            return CustomEmojiTextComposer.text(value, context: emoji)
        }
        if !emoji.isEmpty {
            var parts = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: value.runs.count)
            for segment in CustomEmojiText.segments(of: value, resolvable: emoji.resolvable) {
                switch segment {
                case .text(let text):
                    parts.appendInterpolation(Self.text(text))
                case .emoji(_, let original):
                    let image = CustomEmojiTextComposer.text(original, context: emoji)
                    let matches = original.runs.contains { $0[TimelineMatchAttribute.self] == true }
                    parts.appendInterpolation(matches ? image.customAttribute(Self.search) : image)
                }
            }
            return Text(LocalizedStringKey(stringInterpolation: parts), tableName: "TimelineTextMark")
        }
        var parts = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: value.runs.count)
        for (match, mention, range) in value.runs[TimelineMatchAttribute.self, MarkdownMentionAttribute.self] {
            let run = CustomEmojiTextComposer.text(AttributedString(value[range]), context: emoji)
            if match == true {
                parts.appendInterpolation(run.customAttribute(Self.search))
            } else if mention == true {
                parts.appendInterpolation(run.customAttribute(Self.mention))
            } else {
                parts.appendInterpolation(run)
            }
        }
        return Text(LocalizedStringKey(stringInterpolation: parts), tableName: "TimelineTextMark")
    }
}

struct TimelineTextRenderer: TextRenderer {
    static let mentionHorizontalOutset: CGFloat = 2
    var mentionColor: Color = .clear

    var displayPadding: EdgeInsets {
        EdgeInsets(top: 0, leading: Self.mentionHorizontalOutset, bottom: 0, trailing: Self.mentionHorizontalOutset)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                if let mark = run[TimelineTextMark.self] {
                    let bounds = run.typographicBounds.rect.insetBy(dx: mark == .mention ? -Self.mentionHorizontalOutset : 0, dy: 0)
                    context.fill(Path(roundedRect: bounds, cornerRadius: 4, style: .continuous),
                                 with: .color(mark == .search ? .cyan : mentionColor))
                }
                context.draw(run)
            }
        }
    }
}

/// Filenames, authors, and card labels share the marked text used in message bodies.
struct TimelineSearchText: View {
    @Environment(\.timelineSearchQuery) private var query
    let value: String

    var keepsMatchVisible = false

    init(_ value: String, keepsMatchVisible: Bool = false) {
        self.value = value
        self.keepsMatchVisible = keepsMatchVisible
    }

    var body: some View {
        if let query {
            if keepsMatchVisible, let excerpt = ConversationSearchEngine.excerpt(in: value, matching: query, leadingContext: 0) {
                ViewThatFits(in: .horizontal) {
                    marked(value, query: query).fixedSize(horizontal: true, vertical: false)
                    marked(excerpt, query: query)
                }
            } else {
                marked(value, query: query)
            }
        } else {
            Text(verbatim: value)
        }
    }

    private func marked(_ text: String, query: String) -> some View {
        TimelineTextMark.text(AttributedString(text).highlightingTimelineMatches(query))
            .textRenderer(TimelineTextRenderer())
    }
}

/// Recursive renderer for `MarkdownDisplayBlock` trees inside a message
/// bubble. Inline styling lives in the pre-built `AttributedString`s; this
/// view only adds block chrome (quote bars, code backgrounds, list markers).
///
/// Width discipline: nothing here may be greedy-horizontal (no `Divider`, no
/// `ScrollView`, no `maxWidth: .infinity`) or every markdown bubble balloons
/// to the timeline's full width.
struct MarkdownMessageView: View {
    @Environment(\.timelineSearchQuery) private var searchQuery
    @Environment(\.messageTextIsOutgoing) private var isOutgoing
    @Environment(\.customEmojiInline) private var customEmoji
    let blocks: [MarkdownDisplayBlock]
    var quoteBar: Color = .accentColor
    var indentDepth: Int = 0
    var spacing: CGFloat = 8

    /// Quote-bar chrome stops accumulating past this depth so deeply nested
    /// content doesn't march off the right edge of a narrow bubble; the
    /// builder's render-depth cap still bounds the content itself.
    static func isIndentFrozen(at depth: Int) -> Bool {
        depth >= MarkdownMessageBuilder.maxIndentDepth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(blocks.indices, id: \.self) { index in
                blockView(blocks[index])
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownDisplayBlock) -> some View {
        switch block {
        case .paragraph(let text), .heading(let text):
            MarkdownLinkText(text.highlightingTimelineMatches(searchQuery))
                .fixedSize(horizontal: false, vertical: true)
                .modifier(MarkdownTimestampAccessibility(text: text))

        case .codeBlock(let code, let language):
            VStack(alignment: .leading, spacing: 6) {
                if let language {
                    TimelineSearchText(language)
                        .lineLimit(1)
                        .font(.caption2.weight(.medium))
                        .opacity(0.7)
                }
                TimelineTextMark.text(code.highlightingTimelineMatches(searchQuery), emoji: customEmoji)
                    .textRenderer(TimelineTextRenderer())
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .background(MessageBubblePalette.foreground(isFromMe: isOutgoing).opacity(isOutgoing ? 0.12 : 0.06),
                        in: .rect(cornerRadius: MessageBubbleReplyLayout.cardCornerRadius))

        case .blockQuote(let nested):
            if Self.isIndentFrozen(at: indentDepth) {
                MarkdownMessageView(
                    blocks: nested,
                    quoteBar: quoteBar,
                    indentDepth: indentDepth + 1,
                    spacing: spacing
                )
            } else {
                HStack(alignment: .top, spacing: 7) {
                    Capsule()
                        .fill(quoteBar)
                        .frame(width: 3)
                    MarkdownMessageView(
                        blocks: nested,
                        quoteBar: quoteBar,
                        indentDepth: indentDepth + 1,
                        spacing: spacing
                    )
                    .layoutPriority(1)
                }
                // Width-only Capsule is greedy vertically without this, same
                // constraint as the reply quote bar in MessageBubble.
                .fixedSize(horizontal: false, vertical: true)
            }

        case .list(let items, let tight):
            VStack(alignment: .leading, spacing: tight ? 2 : 8) {
                ForEach(items.indices, id: \.self) { index in
                    listRow(items[index])
                }
            }
            .fixedSize(horizontal: false, vertical: true)

        case .thematicBreak:
            RoundedRectangle(cornerRadius: 0.5)
                .frame(width: 72, height: 1)
                .opacity(0.25)
                .padding(.vertical, 2)
        }
    }

    private func listRow(_ item: MarkdownDisplayListItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            markerView(item.marker)
                .fixedSize()
            MarkdownMessageView(
                blocks: item.blocks,
                quoteBar: quoteBar,
                indentDepth: indentDepth + 1,
                spacing: 2
            )
            .layoutPriority(1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func markerView(_ marker: MarkdownDisplayListItem.Marker) -> some View {
        switch marker {
        case .bullet:
            Text(verbatim: "•")
        case .ordered(let label):
            Text(label)
                .monospacedDigit()
        case .task(let done):
            Image(systemName: done ? "checkmark.square" : "square")
                .font(.subheadline)
                .accessibilityLabel(done ? L10n.string("Completed task") : L10n.string("Open task"))
        }
    }
}

/// VoiceOver hears a timestamp as displayed ("in 5 minutes"); the absolute
/// instant is offered as custom content. SwiftUI `Text` has no per-run
/// replacement label, and Foundation's accessibility attributes only adjust
/// speech (pitch, spelling, phonetics), so the description cannot ride the run.
private struct MarkdownTimestampAccessibility: ViewModifier {
    let descriptions: [String]

    init(text: AttributedString) {
        descriptions = MarkdownTimestampDescriptionAttribute.descriptions(in: text)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if descriptions.isEmpty {
            content
        } else {
            content.accessibilityCustomContent(
                Text(L10n.string("Exact time")),
                Text(verbatim: descriptions.joined(separator: "; "))
            )
        }
    }
}

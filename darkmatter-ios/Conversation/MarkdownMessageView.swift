import SwiftUI

/// Recursive renderer for `MarkdownDisplayBlock` trees inside a message
/// bubble. Inline styling lives in the pre-built `AttributedString`s; this
/// view only adds block chrome (quote bars, code backgrounds, list markers).
///
/// Width discipline: nothing here may be greedy-horizontal (no `Divider`, no
/// `ScrollView`, no `maxWidth: .infinity`) or every markdown bubble balloons
/// to the timeline's full width.
struct MarkdownMessageView: View {
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
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownDisplayBlock) -> some View {
        switch block {
        case .paragraph(let text), .heading(let text):
            Text(text)

        case .codeBlock(let code):
            Text(code)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.08))
                )

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
            MarkdownMessageView(
                blocks: item.blocks,
                quoteBar: quoteBar,
                indentDepth: indentDepth + 1,
                spacing: 2
            )
        }
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

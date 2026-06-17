import Foundation
import MarmotKit

/// Flattens a markdown AST to plain text for one-line surfaces (chat-list
/// rows, reply quotes): syntax dropped, text kept, links reduced to their
/// labels. NOT sanitized — every caller already pipes the result through
/// `ProfileSanitizer.singleLine`, which strips spoofing characters and caps
/// length.
enum MarkdownPlainText {

    /// Previews show at most ~140 characters; these caps just bound the work
    /// on hostile inputs, not the display.
    private static let maxCharacters = 1000
    private static let maxNodes = 2000

    /// nil when the document is empty or flattens to whitespace.
    static func flatten(
        _ document: MarkdownDocumentFfi,
        mentionDisplayName: MarkdownMentionResolver? = nil
    ) -> String? {
        guard !document.blocks.isEmpty else { return nil }
        var state = State(mentionDisplayName: mentionDisplayName)
        appendBlocks(document.blocks, to: &state, depth: 0)
        let trimmed = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private struct State {
        var mentionDisplayName: MarkdownMentionResolver?
        var text = ""
        var nodes = 0

        var exhausted: Bool {
            nodes >= maxNodes || text.count >= maxCharacters
        }

        mutating func consumeNode() -> Bool {
            guard !exhausted else { return false }
            nodes += 1
            return true
        }

        mutating func append(_ piece: String) {
            let collapsed = piece
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !collapsed.isEmpty else { return }
            if !text.isEmpty { text += " " }
            text += String(collapsed.prefix(max(0, maxCharacters - text.count)))
        }
    }

    private static func appendBlocks(_ blocks: [MarkdownBlockFfi], to state: inout State, depth: Int) {
        guard depth < MarkdownMessageBuilder.maxRenderDepth else { return }
        for block in blocks {
            guard state.consumeNode() else { return }
            switch block {
            case .paragraph(let inlines), .heading(_, let inlines):
                appendInlines(inlines, to: &state, depth: depth)
            case .codeBlock(_, _, let content), .mathBlock(let content):
                state.append(content)
            case .blockQuote(let nested):
                appendBlocks(nested, to: &state, depth: depth + 1)
            case .list(_, _, let items):
                for item in items {
                    guard state.consumeNode() else { return }
                    appendBlocks(item.blocks, to: &state, depth: depth + 1)
                }
            case .table(_, let header, let rows):
                appendTableRow(header, to: &state, depth: depth)
                guard !state.exhausted else { return }
                for row in rows {
                    appendTableRow(row, to: &state, depth: depth)
                    guard !state.exhausted else { return }
                }
            case .thematicBreak:
                break
            }
        }
    }

    private static func appendTableRow(_ cells: [MarkdownTableCellFfi], to state: inout State, depth: Int) {
        guard state.consumeNode() else { return }
        for cell in cells {
            guard state.consumeNode() else { return }
            appendInlines(cell.inlines, to: &state, depth: depth)
        }
    }

    private static func appendInlines(_ inlines: [MarkdownInlineFfi], to state: inout State, depth: Int) {
        guard depth < MarkdownMessageBuilder.maxRenderDepth else { return }
        for inline in inlines {
            guard state.consumeNode() else { return }
            switch inline {
            case .text(let content), .code(let content), .math(let content):
                state.append(content)
            case .softBreak, .hardBreak:
                break
            case .emph(let children), .strong(let children), .strikethrough(let children):
                appendInlines(children, to: &state, depth: depth + 1)
            case .link(_, _, let children):
                appendInlines(children, to: &state, depth: depth + 1)
            case .image(_, _, let alt):
                appendInlines(alt, to: &state, depth: depth + 1)
            case .autolink(let url, _):
                state.append(url)
            case .nostrMention(let entity):
                if let name = state.mentionDisplayName?(entity) {
                    state.append("@" + name)
                } else {
                    state.append("@" + MarkdownMessageBuilder.truncatedBech32(entity.bech32))
                }
            case .nostrUri(let entity):
                if let name = state.mentionDisplayName?(entity) {
                    state.append("@" + name)
                } else {
                    state.append(MarkdownMessageBuilder.truncatedBech32(entity.bech32))
                }
            }
        }
    }
}

import SwiftUI
import MarmotKit

/// Resolves a nostr mention entity to a known display name, nil to keep the
/// truncated-bech32 fallback. Injected so the pure builder/flattener stay
/// testable without an AppState.
typealias MarkdownMentionResolver = (MarkdownNostrEntityFfi) -> String?

/// Display model for a chat message's markdown AST: each leaf block carries a
/// pre-built `AttributedString` so the view layer is a dumb recursive walk.
///
/// Built style-agnostic — no foreground colors are baked in. The bubble owns
/// `.foregroundStyle` and `.tint`; links carry underlines so they stay
/// distinguishable when tint matches the body color (sent gradient).
enum MarkdownDisplayBlock: Equatable {
    case paragraph(AttributedString)
    case heading(AttributedString)
    case codeBlock(AttributedString)
    case blockQuote([MarkdownDisplayBlock])
    case list(items: [MarkdownDisplayListItem], tight: Bool)
    case thematicBreak
}

struct MarkdownDisplayListItem: Equatable {
    enum Marker: Equatable {
        case bullet
        case ordered(label: String)
        case task(done: Bool)
    }

    let marker: Marker
    let blocks: [MarkdownDisplayBlock]
}

/// Walks the Rust-parsed markdown AST (`MarkdownDocumentFfi`) into the display
/// model. Pure and synchronous; testable without a Marmot runtime.
///
/// The AST arrives from untrusted relays via plaintext Rust never sanitized
/// for display, so every text run is stripped here (Trojan-Source/bidi/zero
/// width) and the whole walk is budgeted: total characters, total nodes, and
/// recursion depth — independent of Rust's own FFI depth cap.
enum MarkdownMessageBuilder {

    static let maxCharacters = ProfileSanitizer.maxMessageLength
    static let maxNodes = 2000
    static let maxRenderDepth = 24
    /// Visual indentation stops deepening past this; rendering depth continues
    /// up to `maxRenderDepth` so content isn't lost, it just stops marching
    /// rightward in narrow bubbles.
    static let maxIndentDepth = 6

    /// Schemes a message link may carry. Upstream only filters *autolink*
    /// schemes; explicit `[label](dest)` destinations arrive unfiltered, so
    /// this allowlist is the render-side gate against javascript:/data:/file:.
    private static let allowedLinkSchemes: Set<String> = [
        "http", "https", "mailto", "tel",
        "darkmatter", "whitenoise", "whitenoise-staging", "nostr",
    ]

    struct Budget {
        var remainingCharacters = MarkdownMessageBuilder.maxCharacters
        var remainingNodes = MarkdownMessageBuilder.maxNodes
        var truncated = false

        mutating func consumeNode() -> Bool {
            guard remainingNodes > 0 else {
                truncated = true
                return false
            }
            remainingNodes -= 1
            return true
        }

        mutating func take(_ text: String) -> Substring {
            guard remainingCharacters > 0 else {
                if !text.isEmpty { truncated = true }
                return Substring()
            }
            if text.count <= remainingCharacters {
                remainingCharacters -= text.count
                return text[...]
            }
            truncated = true
            let cut = text.prefix(remainingCharacters)
            remainingCharacters = 0
            return cut
        }
    }

    /// nil when the document has no blocks or nothing renderable survives
    /// sanitization — callers fall back to the plain-text bubble path.
    static func displayBlocks(
        for document: MarkdownDocumentFfi,
        mentionDisplayName: MarkdownMentionResolver? = nil
    ) -> [MarkdownDisplayBlock]? {
        guard !document.blocks.isEmpty else { return nil }
        var budget = Budget()
        var blocks = walkBlocks(
            document.blocks,
            budget: &budget,
            depth: 0,
            mentionDisplayName: mentionDisplayName
        )
        guard !blocks.isEmpty else { return nil }
        if budget.truncated {
            blocks.append(.paragraph(AttributedString("…")))
        }
        return blocks
    }

    /// Inline flattening, exposed for tests.
    static func attributedString(
        for inlines: [MarkdownInlineFfi],
        baseFont: Font = .body,
        budget: inout Budget,
        mentionDisplayName: MarkdownMentionResolver? = nil
    ) -> AttributedString {
        var out = AttributedString()
        var context = InlineContext(baseFont: baseFont)
        context.mentionDisplayName = mentionDisplayName
        walkInlines(inlines, into: &out, context: context, budget: &budget, depth: 0)
        return out
    }

    static func truncatedBech32(_ bech32: String) -> String {
        let clean = ProfileSanitizer.textRun(bech32)
        guard clean.count > 16 else { return clean }
        return "\(clean.prefix(8))…\(clean.suffix(4))"
    }

    /// Render-side scheme gate for link destinations. Returns nil (no link,
    /// children render as plain text) for disallowed or unparseable URLs.
    static func allowedLinkURL(_ raw: String) -> URL? {
        let trimmed = ProfileSanitizer.textRun(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              allowedLinkSchemes.contains(scheme)
        else { return nil }
        return components.url
    }

    // MARK: - Block walk

    private static func walkBlocks(
        _ blocks: [MarkdownBlockFfi],
        budget: inout Budget,
        depth: Int,
        mentionDisplayName: MarkdownMentionResolver?
    ) -> [MarkdownDisplayBlock] {
        guard depth < maxRenderDepth else {
            budget.truncated = true
            return []
        }
        var out: [MarkdownDisplayBlock] = []
        for block in blocks {
            guard budget.consumeNode() else { break }
            switch block {
            case .paragraph(let inlines):
                let attributed = attributedString(
                    for: inlines,
                    baseFont: .body,
                    budget: &budget,
                    mentionDisplayName: mentionDisplayName
                )
                if hasVisibleContent(attributed) {
                    out.append(.paragraph(attributed))
                }

            case .heading(let level, let inlines):
                let attributed = attributedString(
                    for: inlines,
                    baseFont: headingFont(level: level),
                    budget: &budget,
                    mentionDisplayName: mentionDisplayName
                )
                if hasVisibleContent(attributed) {
                    out.append(.heading(attributed))
                }

            case .thematicBreak:
                out.append(.thematicBreak)

            case .codeBlock(_, _, let content):
                appendCodeBlock(content, to: &out, budget: &budget)

            case .blockQuote(let children):
                let nested = walkBlocks(
                    children,
                    budget: &budget,
                    depth: depth + 1,
                    mentionDisplayName: mentionDisplayName
                )
                if !nested.isEmpty {
                    out.append(.blockQuote(nested))
                }

            case .list(let kind, let tight, let items):
                let displayItems = listItems(
                    kind: kind,
                    items: items,
                    budget: &budget,
                    depth: depth,
                    mentionDisplayName: mentionDisplayName
                )
                if !displayItems.isEmpty {
                    out.append(.list(items: displayItems, tight: tight))
                }

            case .table(_, let header, let rows):
                appendTable(
                    header: header,
                    rows: rows,
                    to: &out,
                    budget: &budget,
                    mentionDisplayName: mentionDisplayName
                )

            case .mathBlock(let content):
                appendCodeBlock(content, to: &out, budget: &budget)
            }
        }
        return out
    }

    private static func appendCodeBlock(
        _ content: String,
        to out: inout [MarkdownDisplayBlock],
        budget: inout Budget
    ) {
        var clean = ProfileSanitizer.textRun(content)
        while clean.hasSuffix("\n") { clean.removeLast() }
        let piece = String(budget.take(clean))
        guard !piece.isEmpty, piece.contains(where: { !$0.isWhitespace }) else { return }
        var attributes = AttributeContainer()
        attributes.font = Font.body.monospaced()
        out.append(.codeBlock(AttributedString(piece, attributes: attributes)))
    }

    /// Tables degrade to one bold paragraph for the header and a plain
    /// paragraph per row — chat bubbles are too narrow for real grids.
    private static func appendTable(
        header: [MarkdownTableCellFfi],
        rows: [[MarkdownTableCellFfi]],
        to out: inout [MarkdownDisplayBlock],
        budget: inout Budget,
        mentionDisplayName: MarkdownMentionResolver?
    ) {
        if let headerLine = tableRowString(
            cells: header, bold: true, budget: &budget, mentionDisplayName: mentionDisplayName
        ) {
            out.append(.paragraph(headerLine))
        }
        for row in rows {
            guard budget.consumeNode() else { break }
            if let rowLine = tableRowString(
                cells: row, bold: false, budget: &budget, mentionDisplayName: mentionDisplayName
            ) {
                out.append(.paragraph(rowLine))
            }
        }
    }

    private static func tableRowString(
        cells: [MarkdownTableCellFfi],
        bold: Bool,
        budget: inout Budget,
        mentionDisplayName: MarkdownMentionResolver?
    ) -> AttributedString? {
        var line = AttributedString()
        var context = InlineContext(baseFont: .body)
        context.bold = bold
        context.mentionDisplayName = mentionDisplayName
        for (index, cell) in cells.enumerated() {
            if index > 0, !line.characters.isEmpty {
                line += AttributedString(String(budget.take("  ")))
            }
            walkInlines(cell.inlines, into: &line, context: context, budget: &budget, depth: 0)
        }
        return hasVisibleContent(line) ? line : nil
    }

    private static func listItems(
        kind: MarkdownListKindFfi,
        items: [MarkdownListItemFfi],
        budget: inout Budget,
        depth: Int,
        mentionDisplayName: MarkdownMentionResolver?
    ) -> [MarkdownDisplayListItem] {
        var out: [MarkdownDisplayListItem] = []
        for (index, item) in items.enumerated() {
            guard budget.consumeNode() else { break }
            let blocks = walkBlocks(
                item.blocks,
                budget: &budget,
                depth: depth + 1,
                mentionDisplayName: mentionDisplayName
            )
            guard !blocks.isEmpty else { continue }
            out.append(MarkdownDisplayListItem(
                marker: marker(kind: kind, index: index, checked: item.checked),
                blocks: blocks
            ))
        }
        return out
    }

    private static func marker(
        kind: MarkdownListKindFfi,
        index: Int,
        checked: Bool?
    ) -> MarkdownDisplayListItem.Marker {
        if let checked {
            return .task(done: checked)
        }
        switch kind {
        case .bullet:
            return .bullet
        case .ordered(let start, let delimiter):
            let number = UInt64(start) + UInt64(index)
            let cleanDelimiter = delimiter == ")" ? ")" : "."
            return .ordered(label: "\(number)\(cleanDelimiter)")
        }
    }

    private static func headingFont(level: UInt8) -> Font {
        switch max(1, min(level, 6)) {
        case 1: return .title3.bold()
        case 2: return .headline
        default: return .subheadline.bold()
        }
    }

    private static func hasVisibleContent(_ attributed: AttributedString) -> Bool {
        attributed.characters.contains { !$0.isWhitespace }
    }

    // MARK: - Inline walk

    private struct InlineContext {
        var baseFont: Font
        var bold = false
        var italic = false
        var strikethrough = false
        var monospaced = false
        var link: URL?
        var mentionDisplayName: MarkdownMentionResolver?

        var font: Font {
            var font = baseFont
            if monospaced { font = font.monospaced() }
            if bold { font = font.bold() }
            if italic { font = font.italic() }
            return font
        }
    }

    private static func walkInlines(
        _ inlines: [MarkdownInlineFfi],
        into out: inout AttributedString,
        context: InlineContext,
        budget: inout Budget,
        depth: Int
    ) {
        guard depth < maxRenderDepth else {
            budget.truncated = true
            return
        }
        for inline in inlines {
            guard budget.consumeNode() else { return }
            switch inline {
            case .text(let content):
                append(content, to: &out, context: context, budget: &budget)

            case .softBreak:
                appendBreak(" ", to: &out, budget: &budget)

            case .hardBreak:
                appendBreak("\n", to: &out, budget: &budget)

            case .code(let content):
                var code = context
                code.monospaced = true
                append(content, to: &out, context: code, budget: &budget, codeBackground: true)

            case .math(let content):
                var math = context
                math.monospaced = true
                append(content, to: &out, context: math, budget: &budget, codeBackground: true)

            case .emph(let children):
                var nested = context
                nested.italic = true
                walkInlines(children, into: &out, context: nested, budget: &budget, depth: depth + 1)

            case .strong(let children):
                var nested = context
                nested.bold = true
                walkInlines(children, into: &out, context: nested, budget: &budget, depth: depth + 1)

            case .strikethrough(let children):
                var nested = context
                nested.strikethrough = true
                walkInlines(children, into: &out, context: nested, budget: &budget, depth: depth + 1)

            case .link(let dest, _, let children):
                var nested = context
                if context.link == nil, let url = allowedLinkURL(dest) {
                    nested.link = url
                }
                walkInlines(children, into: &out, context: nested, budget: &budget, depth: depth + 1)

            case .image(let dest, _, let alt):
                appendImage(dest: dest, alt: alt, to: &out, context: context, budget: &budget, depth: depth)

            case .autolink(let url, let kind):
                appendAutolink(url, kind: kind, to: &out, context: context, budget: &budget)

            case .nostrMention(let entity):
                appendNostrEntity(entity, prefix: "@", to: &out, context: context, budget: &budget)

            case .nostrUri(let entity):
                appendNostrEntity(entity, prefix: "", to: &out, context: context, budget: &budget)
            }
        }
    }

    /// Images are never fetched — arbitrary-host loads leak the reader's IP in
    /// an E2EE chat. The alt text renders as a link to the destination; inside
    /// an outer link the outer destination wins.
    private static func appendImage(
        dest: String,
        alt: [MarkdownInlineFfi],
        to out: inout AttributedString,
        context: InlineContext,
        budget: inout Budget,
        depth: Int
    ) {
        var nested = context
        if context.link == nil, let url = allowedLinkURL(dest) {
            nested.link = url
        }
        let lengthBefore = out.characters.count
        walkInlines(alt, into: &out, context: nested, budget: &budget, depth: depth + 1)
        if out.characters.count == lengthBefore {
            append(L10n.string("Image"), to: &out, context: nested, budget: &budget)
        }
    }

    private static func appendAutolink(
        _ url: String,
        kind: MarkdownAutolinkKindFfi,
        to out: inout AttributedString,
        context: InlineContext,
        budget: inout Budget
    ) {
        var nested = context
        if context.link == nil {
            let dest: String
            switch kind {
            case .email:
                dest = url.lowercased().hasPrefix("mailto:") ? url : "mailto:\(url)"
            case .uri:
                dest = url
            }
            nested.link = allowedLinkURL(dest)
        }
        append(url, to: &out, context: nested, budget: &budget)
    }

    /// npub/nprofile entities deep-link to the profile screen via a synthetic
    /// `nostr:` URL; other entity kinds render styled but inert. When the
    /// profile is known, the mention reads `@Display Name` (bold, body font)
    /// instead of the truncated bech32.
    private static func appendNostrEntity(
        _ entity: MarkdownNostrEntityFfi,
        prefix: String,
        to out: inout AttributedString,
        context: InlineContext,
        budget: inout Budget
    ) {
        var nested = context
        if context.link == nil {
            switch entity.hrp {
            case .npub, .nprofile:
                nested.link = allowedLinkURL("nostr:\(ProfileSanitizer.textRun(entity.bech32))")
            case .note, .nevent, .naddr, .nrelay:
                break
            }
        }
        if let name = context.mentionDisplayName?(entity) {
            nested.bold = true
            append("@" + name, to: &out, context: nested, budget: &budget)
            return
        }
        nested.monospaced = true
        append(prefix + truncatedBech32(entity.bech32), to: &out, context: nested, budget: &budget)
    }

    private static func append(
        _ raw: String,
        to out: inout AttributedString,
        context: InlineContext,
        budget: inout Budget,
        codeBackground: Bool = false
    ) {
        let piece = String(budget.take(ProfileSanitizer.textRun(raw)))
        guard !piece.isEmpty else { return }
        var attributes = AttributeContainer()
        attributes.font = context.font
        if context.strikethrough {
            attributes.strikethroughStyle = .single
        }
        if let link = context.link {
            attributes.link = link
            attributes.underlineStyle = .single
        }
        if codeBackground {
            attributes.backgroundColor = Color.primary.opacity(0.08)
        }
        out += AttributedString(piece, attributes: attributes)
    }

    /// Breaks are structural, not attacker text: soft → space, hard → newline,
    /// and runs never exceed one blank line (mirrors `clampBlankLineRuns`).
    private static func appendBreak(
        _ piece: String,
        to out: inout AttributedString,
        budget: inout Budget
    ) {
        guard !out.characters.isEmpty else { return }
        if piece == "\n" {
            let trailing = out.characters.suffix(2)
            if trailing.count == 2, trailing.allSatisfy({ $0 == "\n" }) { return }
        } else if out.characters.last == " " || out.characters.last == "\n" {
            return
        }
        guard !budget.take(piece).isEmpty else { return }
        out += AttributedString(piece)
    }
}

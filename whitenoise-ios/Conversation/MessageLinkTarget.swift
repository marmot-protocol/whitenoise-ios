import Foundation

nonisolated struct MessageLinkTarget: Equatable, Hashable {
    private static let maxDisplayCharacters = 64

    let url: URL
    let copyText: String

    init?(url: URL) {
        guard let copyText = MessageLinkPolicy.copyText(for: url) else { return nil }
        self.url = url
        self.copyText = copyText
    }

    static func targets(in blocks: [MarkdownDisplayBlock]?) -> [MessageLinkTarget] {
        var seen = Set<String>()
        var targets: [MessageLinkTarget] = []
        for text in paragraphs(in: blocks ?? []) {
            for segment in MessageLinkSegment.segments(of: text) {
                guard let target = segment.target, seen.insert(target.copyText).inserted else { continue }
                targets.append(target)
            }
        }
        return targets
    }

    static func accessibilityActionTitles(for targets: [MessageLinkTarget]) -> [String] {
        guard targets.count > 1 else { return targets.map { _ in L10n.string("Copy Link") } }
        var occurrences: [String: Int] = [:]
        let displays = targets.map(\.displayText)
        let counts = Dictionary(displays.map { ($0, 1) }, uniquingKeysWith: +)
        return displays.map { display in
            guard counts[display, default: 0] > 1 else { return L10n.formatted("Copy Link: %@", display) }
            let occurrence = occurrences[display, default: 0] + 1
            occurrences[display] = occurrence
            return L10n.formatted("Copy Link: %@", "\(display) (\(occurrence))")
        }
    }

    var displayText: String {
        let sanitized = ContentSanitizer.textRun(Self.displaySource(for: url))
        guard sanitized.count > Self.maxDisplayCharacters else { return sanitized }
        let prefixCount = (Self.maxDisplayCharacters - 1) / 2
        let suffixCount = Self.maxDisplayCharacters - 1 - prefixCount
        return "\(sanitized.prefix(prefixCount))…\(sanitized.suffix(suffixCount))"
    }

    private static func displaySource(for url: URL) -> String {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return url.absoluteString }
        let path = url.path(percentEncoded: false)
        var source = host + (path == "/" ? "" : path)
        if let query = url.query(percentEncoded: false), !query.isEmpty {
            source += "?\(query)"
        }
        return source
    }

    private static func paragraphs(in blocks: [MarkdownDisplayBlock]) -> [AttributedString] {
        blocks.flatMap { block -> [AttributedString] in
            switch block {
            case .paragraph(let text), .heading(let text):
                return [text]
            case .blockQuote(let nested):
                return paragraphs(in: nested)
            case .list(let items, _):
                return items.flatMap { paragraphs(in: $0.blocks) }
            case .codeBlock, .thematicBreak:
                return []
            }
        }
    }
}

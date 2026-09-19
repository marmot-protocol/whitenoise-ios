import Foundation
import MarmotKit

/// Pure projection rules for the shared-media library: category split,
/// month grouping, and link extraction from message history.
nonisolated enum SharedMediaLibraryPresentation {
    enum Category: String, CaseIterable, Identifiable {
        case media
        case voice
        case files
        case links

        var id: String { rawValue }
    }

    static func voiceItems(from items: [GroupSharedMediaItem]) -> [GroupSharedMediaItem] {
        items.filter { $0.attachment.kind == .audio }
    }

    static func fileItems(from items: [GroupSharedMediaItem]) -> [GroupSharedMediaItem] {
        items.filter { !$0.isVisual && $0.attachment.kind != .audio }
    }

    // MARK: - Month sections

    struct MonthSection: Identifiable, Equatable {
        let id: String
        let title: String
        var items: [GroupSharedMediaItem]
    }

    /// Contiguous month sections preserve MDK order even when display dates move backward.
    static func monthSections(
        _ items: [GroupSharedMediaItem],
        calendar: Calendar = .current,
        locale: Locale = AppLanguage.currentLocale
    ) -> [MonthSection] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMMM y")

        var sections: [MonthSection] = []
        var previousKey: String?
        for item in items {
            let key: String
            let title: String
            if item.timestamp > 0 {
                let date = Date(timeIntervalSince1970: TimeInterval(item.timestamp))
                let components = calendar.dateComponents([.year, .month], from: date)
                key = "\(components.year ?? 0)-\(components.month ?? 0)"
                title = formatter.string(from: date)
            } else {
                key = "undated"
                title = L10n.string("Recent")
            }
            if previousKey == key, !sections.isEmpty {
                sections[sections.count - 1].items.append(item)
            } else {
                sections.append(MonthSection(id: "\(key):\(item.id)", title: title, items: [item]))
                previousKey = key
            }
        }
        return sections
    }

    // MARK: - Links

    /// Minimal shape of a history record for link scanning, so the extraction
    /// rules stay testable without constructing full FFI records.
    struct LinkScanRecord: Equatable {
        let messageIdHex: String
        let kind: UInt64
        let content: String
        let timelineAt: UInt64
    }

    struct LinkItem: Identifiable, Equatable {
        let id: String
        let messageIdHex: String
        let urlString: String
        let display: String
        let timelineAt: UInt64
        /// True for `xn--` (IDN) hosts so the view can flag lookalike domains.
        let hasInternationalizedHost: Bool
    }

    static let chatMessageKind: UInt64 = 9
    static let maxLinkLength = 2048
    private static let trailingTrim = CharacterSet(charactersIn: ").,;:!?]}\"'>")
    private static let leadingTrim = CharacterSet(charactersIn: "([{<\"'")

    /// Extracts HTTP(S) links from chat messages, newest-first input order
    /// preserved, deduplicated per message. Display text is sanitized and
    /// bounded; peer-controlled URLs are never rendered unbounded.
    static func linkItems(from records: [LinkScanRecord]) -> [LinkItem] {
        var results: [LinkItem] = []
        var seen: Set<String> = []
        for record in records where record.kind == chatMessageKind {
            for token in record.content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
                guard let urlString = normalizedLink(String(token)) else { continue }
                let dedupeKey = "\(record.messageIdHex)#\(urlString.lowercased())"
                guard seen.insert(dedupeKey).inserted else { continue }
                let display = ContentSanitizer.compactSingleLine(urlString, maxLength: 120) ?? urlString
                let host = URL(string: urlString)?.host?.lowercased() ?? ""
                results.append(LinkItem(
                    id: dedupeKey,
                    messageIdHex: record.messageIdHex,
                    urlString: urlString,
                    display: display,
                    timelineAt: record.timelineAt,
                    hasInternationalizedHost: host.contains("xn--")
                ))
            }
        }
        return results
    }

    /// Trims wrapping punctuation and validates shape: http(s), a host, and a
    /// bounded length. A scheme embedded mid-token (markdown destinations
    /// like `[x](https://…)`) is sliced out rather than rejected. Returns the
    /// cleaned URL string or nil.
    static func normalizedLink(_ raw: String) -> String? {
        guard raw.count <= maxLinkLength else { return nil }
        var value = raw.trimmingCharacters(in: leadingTrim)
        if let schemeRange = value.range(
            of: "https?://",
            options: [.regularExpression, .caseInsensitive]
        ), schemeRange.lowerBound != value.startIndex {
            value = String(value[schemeRange.lowerBound...])
        }
        while let last = value.unicodeScalars.last, trailingTrim.contains(last) {
            value.removeLast()
        }
        guard value.count <= maxLinkLength else { return nil }
        let lowered = value.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { return nil }
        guard let url = URL(string: value), let host = url.host, !host.isEmpty else { return nil }
        return value
    }
}

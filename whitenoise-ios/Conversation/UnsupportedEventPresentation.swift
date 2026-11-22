import Foundation
import MarmotKit

/// What the conversation shows for an event of a kind this app doesn't render,
/// such as another client's app-defined kind: a collapsed card naming the kind,
/// with the event's own description, and the raw event on request.
nonisolated struct UnsupportedEventPresentation: Equatable {
    static let maxTitleLength = 120
    static let maxSummaryLength = 280

    let kind: UInt64
    /// The event's `subject` or `title` tag, if it has one.
    let title: String?
    /// The event's NIP-31 `alt` tag, which describes it for clients that can't render it.
    let summary: String?

    init(record: AppMessageRecordFfi) {
        self.init(kind: record.kind, tags: record.tags)
    }

    init(kind: UInt64, tags: [MessageTagFfi]) {
        self.kind = kind
        let titleValue = MessageSemantics.firstValue(of: "subject", in: tags)
            ?? MessageSemantics.firstValue(of: "title", in: tags)
        title = ContentSanitizer.compactSingleLine(titleValue, maxLength: Self.maxTitleLength)
        summary = ContentSanitizer.compactSingleLine(
            MessageSemantics.firstValue(of: "alt", in: tags),
            maxLength: Self.maxSummaryLength
        )
    }

    /// "Kind 4242". The number is written without grouping separators.
    static func kindLabel(_ kind: UInt64) -> String {
        L10n.formatted("Kind %@", String(kind))
    }

    /// The event as Nostr JSON, fields in their canonical order, one tag per line.
    /// The inner event is unsigned, so there is no `sig`.
    static func eventJSON(for record: AppMessageRecordFfi) -> String {
        let tagLines = record.tags.map { tag in
            "[" + tag.values.map(jsonString).joined(separator: ", ") + "]"
        }
        let tags = tagLines.isEmpty
            ? "[]"
            : "[\n    " + tagLines.joined(separator: ",\n    ") + "\n  ]"
        return """
        {
          "id": \(jsonString(record.messageIdHex)),
          "pubkey": \(jsonString(record.sender)),
          "created_at": \(record.recordedAt),
          "kind": \(record.kind),
          "tags": \(tags),
          "content": \(jsonString(record.plaintext))
        }
        """
    }

    private static func jsonString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(value), let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }
}

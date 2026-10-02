import Foundation

nonisolated struct LinkPreviewMetadata: Equatable, Sendable {
    static let maximumTitleLength = 200
    static let maximumScannedBytes = 2 * 1024 * 1024

    private static let titleKeys = ["og:title", "twitter:title"]
    private static let imageKeys = [
        "og:image:secure_url",
        "og:image",
        "og:image:url",
        "twitter:image",
        "twitter:image:src",
    ]

    let title: String?
    let imageURL: URL?

    static func previewURL(in blocks: [MarkdownDisplayBlock]?) -> URL? {
        MessageLinkTarget.targets(in: blocks)
            .first { ContentSanitizer.imageURL($0.url.absoluteString) != nil }?
            .url
    }

    static func parse(html data: Data, baseURL: URL) -> LinkPreviewMetadata? {
        let html = String(decoding: data.prefix(maximumScannedBytes), as: UTF8.self)
        let head = html.firstRange(of: /<\/head\s*>/.ignoresCase()).map { String(html[..<$0.lowerBound]) } ?? html
        let properties = metaProperties(in: head)

        let title = (titleKeys.lazy.compactMap { properties[$0] }.first ?? documentTitle(in: head))
            .flatMap { ContentSanitizer.compactSingleLine(decodeEntities($0), maxLength: maximumTitleLength) }
        let imageURL = imageKeys.lazy
            .compactMap { properties[$0] }
            .compactMap { resolvedImageURL(decodeEntities($0), baseURL: baseURL) }
            .first

        guard title != nil || imageURL != nil else { return nil }
        return LinkPreviewMetadata(title: title, imageURL: imageURL)
    }

    private static func metaProperties(in head: String) -> [String: String] {
        var properties: [String: String] = [:]
        for tag in head.matches(of: /<meta\b[^>]*>/.ignoresCase()) {
            let attributes = attributes(in: String(tag.output))
            guard let key = (attributes["property"] ?? attributes["name"])?.lowercased(),
                  let content = attributes["content"],
                  properties[key] == nil
            else { continue }
            properties[key] = content
        }
        return properties
    }

    private static func attributes(in tag: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let pattern = /([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/
        for match in tag.matches(of: pattern) {
            let name = match.output.1.lowercased()
            let value = match.output.2 ?? match.output.3 ?? match.output.4 ?? ""
            if attributes[name] == nil { attributes[name] = String(value) }
        }
        return attributes
    }

    private static func documentTitle(in head: String) -> String? {
        guard let match = head.firstMatch(of: /<title\b[^>]*>([^<]*)<\/title\s*>/.ignoresCase()) else { return nil }
        return String(match.output.1)
    }

    private static func resolvedImageURL(_ raw: String, baseURL: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= ContentSanitizer.maxImageURLLength,
              let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
        else { return nil }
        return ContentSanitizer.imageURL(resolved.absoluteString)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacing(/&(#[xX][0-9A-Fa-f]{1,6}|#[0-9]{1,7}|[A-Za-z]{2,6});/) { match in
            let entity = match.output.1
            switch entity.lowercased() {
            case "amp": return "&"
            case "lt": return "<"
            case "gt": return ">"
            case "quot": return "\""
            case "apos": return "'"
            case "nbsp": return " "
            default: break
            }
            let scalarValue: UInt32? = if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                UInt32(entity.dropFirst(2), radix: 16)
            } else if entity.hasPrefix("#") {
                UInt32(entity.dropFirst())
            } else {
                nil
            }
            guard let scalarValue, let scalar = Unicode.Scalar(scalarValue) else { return String(match.output.0) }
            return String(Character(scalar))
        }
    }
}

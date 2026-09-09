import CoreGraphics
import Foundation

/// The interoperable text envelope used for GIPHY-backed chat messages. This
/// lives in Shared so the main app and notification extension never expose a
/// remote CDN URL as user-facing message text.
nonisolated struct RemoteGiphyMedia: Equatable, Sendable {
    static let maximumWireTextLength = 2_304
    static let maximumAttributionLength = 80

    let url: URL
    let width: Int
    let height: Int
    let attribution: String?

    var wireText: String {
        let credit = attribution.map { "via GIPHY · \($0)" } ?? "via GIPHY"
        return "\(url.absoluteString)\n\(credit)"
    }

    var aspectRatio: CGFloat {
        CGFloat(max(1, width)) / CGFloat(max(1, height))
    }

    static func parse(wireText: String) -> RemoteGiphyMedia? {
        let bounded = String(wireText.prefix(maximumWireTextLength + 1))
        guard bounded.count <= maximumWireTextLength else { return nil }
        let lines = bounded.split(
            separator: "\n",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).map(String.init)
        guard lines.count == 2,
              let url = validatedMediaURL(lines[0]),
              lines[1] == "via GIPHY" || lines[1].hasPrefix("via GIPHY · ")
        else { return nil }

        let attribution: String?
        if lines[1] == "via GIPHY" {
            attribution = nil
        } else {
            let raw = String(lines[1].dropFirst("via GIPHY · ".count))
            guard let sanitized = ContentSanitizer.singleLine(
                raw,
                maxLength: maximumAttributionLength
            ), sanitized == raw else { return nil }
            attribution = sanitized
        }
        return RemoteGiphyMedia(url: url, width: 4, height: 3, attribution: attribution)
    }

    /// The one-line label every preview surface (chat list, reply preview,
    /// notification body) shows for a GIPHY message, or nil when `text` is not
    /// an envelope.
    static func envelopePreviewText(for text: String) -> String? {
        isEnvelopeText(text) ? L10n.string("GIF via GIPHY") : nil
    }

    /// Whether peer text is a GIPHY envelope for display purposes. Looser than
    /// `parse(wireText:)`, which needs the credit line intact to recover
    /// attribution: an envelope whose credit line is missing, unrecognized, or
    /// clipped upstream still has to degrade to the label instead of rendering
    /// the remote CDN URL as message text.
    static func isEnvelopeText(_ text: String) -> Bool {
        let bounded = String(text.prefix(maximumWireTextLength + 1))
        guard bounded.count <= maximumWireTextLength else { return false }
        let firstLine = bounded.prefix { $0 != "\n" }
        return isMediaURLShape(String(firstLine).trimmingCharacters(in: .whitespaces))
    }

    /// Scheme/host shape of an envelope's media URL, without the path checks
    /// `validatedMediaURL` applies, so a URL clipped before its extension is
    /// still recognized as GIF media.
    private static func isMediaURLShape(_ raw: String) -> Bool {
        guard raw.utf8.count <= ContentSanitizer.maxImageURLLength,
              let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              let host = components.host?.lowercased(),
              isAllowedMediaHost(host)
        else { return false }
        return true
    }

    static func validatedMediaURL(_ raw: String) -> URL? {
        guard raw.count <= ContentSanitizer.maxImageURLLength,
              let url = URL(string: raw),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              let host = components.host?.lowercased(),
              isAllowedMediaHost(host),
              ["mp4", "gif", "webp"].contains(url.pathExtension.lowercased()),
              ContentSanitizer.imageURL(raw) != nil
        else { return nil }
        return url
    }

    private static func isAllowedMediaHost(_ host: String) -> Bool {
        guard host.hasSuffix(".giphy.com") else { return false }
        let label = String(host.dropLast(".giphy.com".count))
        if label == "media" || label == "i" { return true }
        guard label.hasPrefix("media") else { return false }
        let suffix = label.dropFirst("media".count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }
}

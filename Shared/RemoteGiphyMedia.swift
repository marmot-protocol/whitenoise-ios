import CoreGraphics
import Foundation

/// The interoperable text envelope used for GIPHY-backed chat messages. This
/// lives in Shared so the main app and notification extension never expose a
/// remote CDN URL as user-facing message text.
nonisolated struct RemoteGiphyMedia: Equatable, Sendable {
    static let maximumWireTextLength = 2_304
    static let maximumAttributionLength = 80
    static let maximumCaptionLength = 1_024
    static let maximumDimension = 4_096

    private static let creditPrefix = "via GIPHY · "
    private static let bareCredit = "via GIPHY"

    let url: URL
    let width: Int
    let height: Int
    let attribution: String?
    /// Composer text sent with the GIF. It rides in the envelope so one Send
    /// stays one message instead of splitting the caption into its own bubble.
    let caption: String?

    init(url: URL, width: Int, height: Int, attribution: String?, caption: String? = nil) {
        self.url = url
        self.width = width
        self.height = height
        self.attribution = attribution
        self.caption = caption
    }

    var wireText: String {
        wireText(caption: caption)
    }

    /// The bare URL/credit envelope. A caption-free GIF is byte-identical to
    /// the pre-caption wire format, so uncaptioned sends stay interoperable.
    var uncaptionedWireText: String {
        wireText(caption: nil)
    }

    func wireText(caption: String?) -> String {
        let credit = attribution.map { "\(Self.creditPrefix)\($0)" } ?? Self.bareCredit
        let envelope = "\(url.absoluteString)\n\(credit)"
        guard let caption = Self.sanitizedCaption(caption) else { return envelope }
        return "\(envelope)\n\(caption)"
    }

    /// Envelope carrying `caption`, or nil when the caption cannot fit the wire
    /// budget. Callers send the overflow as its own message rather than
    /// silently truncating what the user typed.
    func captionedWireText(_ caption: String) -> String? {
        // Checked before sanitizing, which would bound an overlong caption to
        // maximumCaptionLength and quietly drop the rest of what was typed.
        guard caption.count <= Self.maximumCaptionLength else { return nil }
        let candidate = wireText(caption: caption)
        guard candidate.count <= Self.maximumWireTextLength else { return nil }
        return candidate
    }

    var aspectRatio: CGFloat {
        CGFloat(max(1, width)) / CGFloat(max(1, height))
    }

    static func parse(wireText: String) -> RemoteGiphyMedia? {
        let bounded = String(wireText.prefix(maximumWireTextLength + 1))
        guard bounded.count <= maximumWireTextLength else { return nil }
        let lines = bounded.split(
            separator: "\n",
            maxSplits: 2,
            omittingEmptySubsequences: false
        ).map(String.init)
        guard lines.count >= 2,
              let url = validatedMediaURL(lines[0])
        else { return nil }

        let attribution: String?
        if lines[1] == bareCredit {
            attribution = nil
        } else if lines[1].hasPrefix(creditPrefix) {
            let raw = String(lines[1].dropFirst(creditPrefix.count))
            guard let sanitized = ContentSanitizer.singleLine(
                raw,
                maxLength: maximumAttributionLength
            ), sanitized == raw else { return nil }
            attribution = sanitized
        } else {
            return nil
        }

        // An unusable caption is dropped rather than failing the parse; a
        // rejected envelope would render the raw CDN URL as message text.
        return RemoteGiphyMedia(
            url: url,
            width: 4,
            height: 3,
            attribution: attribution,
            caption: lines.count > 2 ? sanitizedCaption(lines[2]) : nil
        )
    }

    static func boundedDimension(_ value: Int) -> Int? {
        (1...maximumDimension).contains(value) ? value : nil
    }

    static func sanitizedCaption(_ raw: String?) -> String? {
        ContentSanitizer.multilineText(raw, maxLength: maximumCaptionLength)
    }

    /// The one-line label every preview surface (chat list, reply preview,
    /// notification body) shows for a GIPHY message, or nil when `text` is not
    /// an envelope.
    static func envelopePreviewText(for text: String) -> String? {
        guard isEnvelopeText(text) else { return nil }
        // A recoverable envelope may carry a caption. Anything else, including
        // a clipped or unrecognized credit line, degrades to the label.
        return parse(wireText: text)?.caption ?? L10n.string("GIF via GIPHY")
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

import Foundation
import MarmotKit
import PhotosUI
import SwiftUI
import UIKit

struct GroupImageSearchResult: Identifiable, Equatable {
    let id: String
    let title: String
    let imageURL: URL
    let thumbnailURL: URL?
    let sourceHost: String?
    let dimensionsLabel: String?
}

struct DuckDuckGoImageSearchClient {
    private static let browserUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 " +
        "Mobile/15E148 Safari/604.1"

    func search(_ rawQuery: String) async throws -> [GroupImageSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw DuckDuckGoImageSearchError.emptyQuery }

        var landing = URLComponents(string: "https://duckduckgo.com/")!
        landing.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "iax", value: "images"),
            URLQueryItem(name: "ia", value: "images")
        ]

        let landingData = try await data(for: landing.url!)
        guard let landingHTML = String(data: landingData, encoding: .utf8),
              let token = Self.vqdToken(in: landingHTML)
        else { throw DuckDuckGoImageSearchError.missingToken }

        var api = URLComponents(string: "https://duckduckgo.com/i.js")!
        api.queryItems = [
            URLQueryItem(name: "l", value: "us-en"),
            URLQueryItem(name: "o", value: "json"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "vqd", value: token),
            URLQueryItem(name: "p", value: "1")
        ]

        let resultsData = try await data(
            for: api.url!,
            referer: URL(string: "https://duckduckgo.com/")!
        )
        return try Self.decodeResults(from: resultsData)
    }

    static func vqdToken(in html: String) -> String? {
        let patterns = [
            #"vqd\s*[:=]\s*['"]([^'"]+)['"]"#,
            #""vqd"\s*:\s*"([^"]+)""#,
            #"vqd=([^&"'\\]+)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            guard let match = regex.firstMatch(in: html, range: range),
                  match.numberOfRanges > 1,
                  let tokenRange = Range(match.range(at: 1), in: html)
            else { continue }
            return String(html[tokenRange]).replacingOccurrences(of: "&amp;", with: "&")
        }
        return nil
    }

    /// Upper bound on the number of search results parsed and rendered. The
    /// DuckDuckGo response is third-party and unbounded, so cap the raw entries
    /// before dedup/sanitization to keep in-memory result count — and the
    /// outbound thumbnail fetches the grid drives as the user scrolls — bounded
    /// regardless of what the search backend returns.
    static let maximumResultCount = 60

    /// Bound and sanitize untrusted result titles before they are rendered as a
    /// fallback when DuckDuckGo's source URL cannot be displayed.
    static let maximumResultTitleLength = 120

    static func decodeResults(from data: Data) throws -> [GroupImageSearchResult] {
        let response = try JSONDecoder().decode(DuckDuckGoImageResponse.self, from: data)
        var seen = Set<String>()
        return response.results.prefix(maximumResultCount).compactMap { raw in
            guard let imageURL = sanitizedImageURL(raw.image) else { return nil }
            guard seen.insert(imageURL.absoluteString).inserted else { return nil }
            let thumbnailURL = sanitizedImageURL(raw.thumbnail)
            return GroupImageSearchResult(
                id: imageURL.absoluteString,
                title: ContentSanitizer.compactSingleLine(raw.title, maxLength: maximumResultTitleLength) ?? "",
                imageURL: imageURL,
                thumbnailURL: thumbnailURL,
                sourceHost: sourceHost(for: raw.sourceURL ?? raw.image),
                dimensionsLabel: dimensionsLabel(width: raw.width, height: raw.height)
            )
        }
    }

    static func sanitizedImageURL(_ raw: String?) -> URL? {
        guard var candidate = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty
        else { return nil }
        if candidate.hasPrefix("//") {
            candidate = "https:" + candidate
        }
        return ContentSanitizer.imageURL(candidate)
    }

    static func request(for url: URL, referer: URL? = nil) -> URLRequest {
        var request = RemoteImageFetch.request(
            for: url,
            accept: "application/json,text/html;q=0.9,*/*;q=0.8"
        )
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        return request
    }

    private func data(for url: URL, referer: URL? = nil) async throws -> Data {
        do {
            let (data, response) = try await RemoteImageFetch.data(
                for: Self.request(for: url, referer: referer)
            )
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else { throw DuckDuckGoImageSearchError.badResponse }
            return data
        } catch PinnedHTTPSFetcher.FetchError.httpStatus {
            throw DuckDuckGoImageSearchError.badResponse
        }
    }

    private static func sourceHost(for raw: String?) -> String? {
        sanitizedImageURL(raw)?.host
    }

    static func dimensionsLabel(
        width: Int?,
        height: Int?,
        locale: Locale = AppLanguage.currentLocale
    ) -> String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return L10n.formatted(
            "%@ × %@",
            arguments: [
                LocalizedNumberLabel.decimal(UInt64(width), locale: locale),
                LocalizedNumberLabel.decimal(UInt64(height), locale: locale)
            ],
            locale: locale
        )
    }
}

private struct DuckDuckGoImageResponse: Decodable {
    let results: [DuckDuckGoImageResult]
}

private struct DuckDuckGoImageResult: Decodable {
    let title: String?
    let image: String
    let thumbnail: String?
    let sourceURL: String?
    let width: Int?
    let height: Int?

    enum CodingKeys: String, CodingKey {
        case title
        case image
        case thumbnail
        case sourceURL = "url"
        case width
        case height
    }
}

enum DuckDuckGoImageSearchError: LocalizedError {
    case emptyQuery
    case missingToken
    case badResponse

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return L10n.string("Enter a search term.")
        case .missingToken:
            return L10n.string("Image search is temporarily unavailable.")
        case .badResponse:
            return L10n.string("Image search returned an unexpected response.")
        }
    }
}


nonisolated struct GroupImageUploadDraft: Equatable {
    let data: Data
    let mediaType: String
    let sourceURL: String?
    let dim: String?
    let thumbhash: String?
    let thumbnail: UIImage?

    init(
        data: Data,
        mediaType: String,
        sourceURL: String?,
        dim: String?,
        thumbhash: String?,
        thumbnail: UIImage? = nil
    ) {
        self.data = data
        self.mediaType = mediaType
        self.sourceURL = sourceURL
        self.dim = dim
        self.thumbhash = thumbhash
        self.thumbnail = thumbnail
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.data == rhs.data
            && lhs.mediaType == rhs.mediaType
            && lhs.sourceURL == rhs.sourceURL
            && lhs.dim == rhs.dim
            && lhs.thumbhash == rhs.thumbhash
    }

    var initialImage: InitialGroupImageFfi {
        InitialGroupImageFfi(
            plaintext: data,
            mediaType: mediaType,
            // Do not publish the web origin as the legacy URL-avatar fallback.
            // The selected bytes must use the encrypted group-image component.
            sourceUrl: nil,
            dim: dim,
            thumbhash: thumbhash
        )
    }
}

enum GroupImageDraftProcessor {
    static func prepare(
        data: Data,
        fileName: String?,
        typeIdentifier: String? = nil,
        sourceURL: URL? = nil
    ) async throws -> GroupImageUploadDraft {
        let attachment = try await MediaDraftProcessor.preparedAttachment(
            from: data,
            fileName: fileName,
            typeIdentifier: typeIdentifier
        )
        return try uploadDraft(from: attachment, sourceURL: sourceURL)
    }

    private static func uploadDraft(
        from attachment: MediaDraftAttachment,
        sourceURL: URL?
    ) throws -> GroupImageUploadDraft {
        guard attachment.kind == .image else {
            throw MediaDraftProcessor.Failure.unsupportedImage
        }
        return GroupImageUploadDraft(
            data: attachment.data,
            mediaType: attachment.mediaType,
            sourceURL: sourceURL?.absoluteString,
            dim: attachment.dim,
            thumbhash: attachment.thumbhash,
            thumbnail: attachment.thumbnail
        )
    }
}

enum GroupImageProgressPhase: Equatable {
    case preparing
    case updating
    case finishing

    var label: String {
        switch self {
        case .preparing:
            L10n.string("Preparing image…")
        case .updating:
            L10n.string("Updating group image…")
        case .finishing:
            L10n.string("Finishing update…")
        }
    }
}

struct GroupImageRemoteThumbnail: View {
    private static let displaySize = CGSize(width: 108, height: 92)
    private static let loadLimiter = CancellableLoadLimiter(maximumConcurrentLoads: 4)

    let url: URL

    @Environment(\.displayScale) private var displayScale
    @State private var phase = Phase.loading

    var body: some View {
        content
            .task(id: url) {
                await loadImage(scale: displayScale)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .success(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        case .failure:
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        }
    }

    private func loadImage(scale: CGFloat) async {
        phase = .loading
        guard let reservation = await Self.loadLimiter.acquire() else { return }
        do {
            try Task.checkCancellation()
            let image = try await RemoteAvatarImageLoader.image(
                for: url,
                maxPixelSize: Self.thumbnailMaxPixelSize(scale: scale),
                scale: scale
            )
            await Self.loadLimiter.release(reservation)
            guard !Task.isCancelled else { return }
            phase = .success(image)
        } catch {
            await Self.loadLimiter.release(reservation)
            guard !Task.isCancelled else { return }
            phase = .failure
        }
    }

    private static func thumbnailMaxPixelSize(scale: CGFloat) -> Int {
        Int(ceil(max(displaySize.width, displaySize.height) * max(scale, 1)))
    }

    private enum Phase {
        case loading
        case success(UIImage)
        case failure
    }
}

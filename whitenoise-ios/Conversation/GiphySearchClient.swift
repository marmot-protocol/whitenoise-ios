import Foundation

nonisolated struct GiphySearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let media: RemoteGiphyMedia
}

nonisolated struct GiphySearchClient {
    static let maximumResultCount = 24
    static let maximumQueryLength = 50
    static let maximumTitleLength = 160
    static let preferredMaximumMediaBytes = 2 * 1_024 * 1_024
    static let maximumMediaBytes = 5 * 1_024 * 1_024

    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let apiKey: String
    var fetch: Fetch = { request in try await RemoteImageFetch.data(for: request) }

    func search(_ rawQuery: String, locale: Locale = AppLanguage.currentLocale) async throws -> [GiphySearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        guard query.count <= Self.maximumQueryLength else { throw GiphySearchError.queryTooLong }
        guard let request = Self.searchRequest(query: query, apiKey: apiKey, locale: locale) else {
            throw GiphySearchError.invalidRequest
        }
        let (data, response) = try await responseWithTransientDNSRetry(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GiphySearchError.badResponse
        }
        return try Self.decodeResults(from: data)
    }

    func resolveAnimatedMedia(for legacyURL: URL) async throws -> RemoteGiphyMedia {
        guard let id = Self.giphyID(from: legacyURL),
              let request = Self.lookupRequest(id: id, apiKey: apiKey)
        else { throw GiphySearchError.invalidRequest }
        let (data, response) = try await responseWithTransientDNSRetry(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GiphySearchError.badResponse
        }
        return try Self.decodeLookupResult(from: data)
    }

    private func responseWithTransientDNSRetry(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        var retryCount = 0
        while true {
            do {
                return try await fetch(request)
            } catch {
                guard Self.shouldRetryLookup(error: error, retryCount: retryCount) else { throw error }
                retryCount += 1
                await Task.yield()
            }
        }
    }

    static func shouldRetryLookup(error: Error, retryCount: Int) -> Bool {
        retryCount < 2
            && (error as? HostResolutionGuard.GuardError) == .resolutionFailed
    }

    static func searchRequest(query: String, apiKey: String, locale: Locale) -> URLRequest? {
        guard !apiKey.isEmpty else { return nil }
        var components = URLComponents(string: "https://api.giphy.com/v1/gifs/search")
        let language = locale.language.languageCode?.identifier ?? "en"
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(maximumResultCount)),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "rating", value: "pg-13"),
            URLQueryItem(name: "lang", value: language),
            URLQueryItem(name: "bundle", value: "messaging_non_clips"),
        ]
        guard let url = components?.url else { return nil }
        return RemoteImageFetch.request(for: url, accept: "application/json")
    }

    static func lookupRequest(id: String, apiKey: String) -> URLRequest? {
        guard isValidGiphyID(id), !apiKey.isEmpty else { return nil }
        var components = URLComponents(string: "https://api.giphy.com/v1/gifs/\(id)")
        components?.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        guard let url = components?.url else { return nil }
        return RemoteImageFetch.request(for: url, accept: "application/json")
    }

    static func giphyID(from mediaURL: URL) -> String? {
        guard RemoteGiphyMedia.validatedMediaURL(mediaURL.absoluteString) != nil else { return nil }
        let components = mediaURL.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return nil }
        let id = components[components.count - 2]
        return isValidGiphyID(id) ? id : nil
    }

    static func decodeResults(from data: Data) throws -> [GiphySearchResult] {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw GiphySearchError.badResponse
        }
        return response.data.prefix(maximumResultCount).compactMap(result(from:))
    }

    static func decodeLookupResult(from data: Data) throws -> RemoteGiphyMedia {
        let response: LookupResponse
        do {
            response = try JSONDecoder().decode(LookupResponse.self, from: data)
        } catch {
            throw GiphySearchError.badResponse
        }
        guard let result = result(from: response.data),
              result.media.url.pathExtension.lowercased() == "gif"
        else { throw GiphySearchError.badResponse }
        return result.media
    }

    private static func result(from item: Item) -> GiphySearchResult? {
        guard let media = mediaRendition(from: item.images) else { return nil }

        let rawAttribution = item.user?.displayName
            ?? item.user?.username
            ?? item.nonEmptyUsername
            ?? item.nonEmptySourceTLD
        let attribution = rawAttribution.flatMap {
            ContentSanitizer.singleLine($0, maxLength: RemoteGiphyMedia.maximumAttributionLength)
        }
        let title = ContentSanitizer.singleLine(
            item.title,
            maxLength: maximumTitleLength
        ) ?? L10n.string("GIF")
        return GiphySearchResult(
            id: String(item.id.prefix(128)),
            title: title,
            media: RemoteGiphyMedia(
                url: media.url,
                width: media.width,
                height: media.height,
                attribution: attribution
            )
        )
    }

    private static func isValidGiphyID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
        }
    }

    private static func mediaRendition(from images: Images) -> (url: URL, width: Int, height: Int)? {
        let renditions = [
            images.original,
            images.downsizedMedium,
            images.downsized,
            images.fixedHeightDownsampled,
            images.fixedWidthDownsampled,
            images.fixedHeight,
            images.fixedWidth,
        ].compactMap { $0 }
        let candidates = renditions.compactMap {
            candidate(url: $0.url, size: $0.size, rendition: $0)
        }
        let preferred = candidates.filter { $0.byteCount <= preferredMaximumMediaBytes }
        let selected = preferred.max { ($0.width * $0.height) < ($1.width * $1.height) }
            ?? candidates.min { $0.byteCount < $1.byteCount }
        return selected.map { ($0.url, $0.width, $0.height) }
    }

    private static func candidate(
        url rawURL: String?,
        size rawSize: String?,
        rendition: Rendition
    ) -> (url: URL, width: Int, height: Int, byteCount: Int)? {
        guard let url = RemoteGiphyMedia.validatedMediaURL(rawURL ?? ""),
              let width = boundedDimension(rendition.width),
              let height = boundedDimension(rendition.height),
              let byteCount = boundedByteCount(rawSize)
        else { return nil }
        return (url, width, height, byteCount)
    }

    private static func boundedDimension(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw) else { return nil }
        return RemoteGiphyMedia.boundedDimension(value)
    }

    private static func boundedByteCount(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw), (1...maximumMediaBytes).contains(value) else { return nil }
        return value
    }

    private struct Response: Decodable {
        let data: [Item]
    }

    private struct LookupResponse: Decodable {
        let data: Item
    }

    private struct Item: Decodable {
        let id: String
        let title: String
        let username: String?
        let sourceTLD: String?
        let user: User?
        let images: Images

        var nonEmptyUsername: String? {
            username?.isEmpty == false ? username : nil
        }

        var nonEmptySourceTLD: String? {
            sourceTLD?.isEmpty == false ? sourceTLD : nil
        }

        enum CodingKeys: String, CodingKey {
            case id, title, username, user, images
            case sourceTLD = "source_tld"
        }
    }

    private struct User: Decodable {
        let username: String?
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case username
            case displayName = "display_name"
        }
    }

    private struct Images: Decodable {
        let fixedWidth: Rendition?
        let fixedHeight: Rendition?
        let fixedWidthDownsampled: Rendition?
        let fixedHeightDownsampled: Rendition?
        let downsized: Rendition?
        let downsizedMedium: Rendition?
        let original: Rendition?

        enum CodingKeys: String, CodingKey {
            case fixedWidth = "fixed_width"
            case fixedHeight = "fixed_height"
            case fixedWidthDownsampled = "fixed_width_downsampled"
            case fixedHeightDownsampled = "fixed_height_downsampled"
            case downsized
            case downsizedMedium = "downsized_medium"
            case original
        }
    }

    private struct Rendition: Decodable {
        let width: String?
        let height: String?
        let url: String?
        let size: String?
        let mp4: String?
        let mp4Size: String?

        enum CodingKeys: String, CodingKey {
            case width, height, url, size, mp4
            case mp4Size = "mp4_size"
        }
    }
}

nonisolated enum GiphySearchError: LocalizedError, Equatable {
    case missingAPIKey
    case queryTooLong
    case invalidRequest
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            L10n.string("GIF search isn't configured in this build.")
        case .queryTooLong:
            L10n.string("That GIF search is too long.")
        case .invalidRequest, .badResponse:
            L10n.string("GIF search is temporarily unavailable.")
        }
    }
}

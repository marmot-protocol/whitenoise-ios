import Foundation
import SwiftUI

struct GroupImageSearchResult: Identifiable, Equatable {
    let id: String
    let title: String
    let imageURL: URL
    let thumbnailURL: URL?
    let sourceHost: String?
    let dimensionsLabel: String?
}

struct DuckDuckGoImageSearchClient {
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

        let resultsData = try await data(for: api.url!)
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

    static func decodeResults(from data: Data) throws -> [GroupImageSearchResult] {
        let response = try JSONDecoder().decode(DuckDuckGoImageResponse.self, from: data)
        var seen = Set<String>()
        return response.results.compactMap { raw in
            guard let imageURL = sanitizedImageURL(raw.image) else { return nil }
            guard seen.insert(imageURL.absoluteString).inserted else { return nil }
            let thumbnailURL = sanitizedImageURL(raw.thumbnail)
            return GroupImageSearchResult(
                id: imageURL.absoluteString,
                title: raw.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
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
        return ProfileSanitizer.imageURL(candidate)
    }

    private func data(for url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json,text/html;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { throw DuckDuckGoImageSearchError.badResponse }
        return data
    }

    private static func sourceHost(for raw: String?) -> String? {
        sanitizedImageURL(raw)?.host
    }

    private static func dimensionsLabel(width: Int?, height: Int?) -> String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width)x\(height)"
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

struct GroupImageURLSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initialURL: String?
    var searchClient = DuckDuckGoImageSearchClient()
    let onSave: (String?) async throws -> Void

    @State private var imageURLDraft: String
    @State private var searchQuery = ""
    @State private var searchResults: [GroupImageSearchResult] = []
    @State private var searchError: String?
    @State private var saveError: String?
    @State private var isSearching = false
    @State private var isSaving = false

    private let resultColumns = [
        GridItem(.adaptive(minimum: 108), spacing: 12)
    ]

    init(
        initialURL: String?,
        searchClient: DuckDuckGoImageSearchClient = DuckDuckGoImageSearchClient(),
        onSave: @escaping (String?) async throws -> Void
    ) {
        self.initialURL = initialURL
        self.searchClient = searchClient
        self.onSave = onSave
        _imageURLDraft = State(initialValue: initialURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                previewSection
                directURLSection
                searchSection

                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Group image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await saveDraft() }
                    }
                    .disabled(saveDisabled)
                }
            }
        }
        .presentationDetents([.large])
    }

    private var previewSection: some View {
        Section {
            HStack(spacing: 16) {
                AvatarBubble(
                    seed: "group-image-preview",
                    title: "Group",
                    pictureURL: validatedDraftURL
                )
                .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 4) {
                    Text(previewTitle)
                        .font(.headline)
                        .lineLimit(1)
                    if let previewSubtitle {
                        Text(previewSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var directURLSection: some View {
        Section("Image URL") {
            TextField("https://example.com/image.jpg", text: $imageURLDraft)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(isSaving)

            if hasDraft && validatedDraftURL == nil {
                Label("Use a public HTTPS image URL.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if normalizedInitialURL != nil {
                Button(role: .destructive) {
                    Task { await save(nil) }
                } label: {
                    Label("Remove image", systemImage: "trash")
                }
                .disabled(isSaving)
            }
        }
    }

    private var searchSection: some View {
        Section("Search the web") {
            HStack(spacing: 8) {
                TextField("Image search", text: $searchQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .disabled(isSearching || isSaving)
                    .onSubmit { Task { await search() } }

                Button {
                    Task { await search() }
                } label: {
                    if isSearching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(searchButtonDisabled)
                .accessibilityLabel("Search the web")
            }

            if let searchError {
                Label(searchError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !searchResults.isEmpty {
                LazyVGrid(columns: resultColumns, spacing: 12) {
                    ForEach(searchResults) { result in
                        Button {
                            imageURLDraft = result.imageURL.absoluteString
                            saveError = nil
                            Haptics.selection()
                        } label: {
                            GroupImageResultCell(
                                result: result,
                                isSelected: result.imageURL == validatedDraftURL
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var trimmedDraft: String {
        imageURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasDraft: Bool {
        !trimmedDraft.isEmpty
    }

    private var validatedDraftURL: URL? {
        Self.validatedImageURL(imageURLDraft)
    }

    private var normalizedDraftURL: String? {
        validatedDraftURL?.absoluteString
    }

    private var normalizedInitialURL: String? {
        Self.validatedImageURL(initialURL)?.absoluteString
    }

    private var saveDisabled: Bool {
        if isSaving { return true }
        if hasDraft && normalizedDraftURL == nil { return true }
        return normalizedDraftURL == normalizedInitialURL
    }

    private var searchButtonDisabled: Bool {
        isSearching || isSaving || searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var previewTitle: String {
        if let host = validatedDraftURL?.host {
            return host
        }
        return hasDraft ? L10n.string("Invalid image URL") : L10n.string("No image selected")
    }

    private var previewSubtitle: String? {
        guard hasDraft else { return nil }
        return validatedDraftURL == nil ? L10n.string("Only public HTTPS image URLs are allowed.") : trimmedDraft
    }

    static func validatedImageURL(_ draft: String?) -> URL? {
        ProfileSanitizer.imageURL(draft)
    }

    private func search() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            searchResults = try await searchClient.search(query)
            if searchResults.isEmpty {
                searchError = L10n.string("No usable HTTPS images found.")
            }
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func saveDraft() async {
        await save(normalizedDraftURL)
    }

    private func save(_ urlString: String?) async {
        if hasDraft && urlString == nil {
            saveError = L10n.string("Use a public HTTPS image URL.")
            Haptics.error()
            return
        }

        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            try await onSave(urlString)
            dismiss()
        } catch {
            saveError = error.localizedDescription
            Haptics.error()
        }
    }
}

private struct GroupImageResultCell: View {
    let result: GroupImageSearchResult
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.secondarySystemBackground))

                AsyncImage(url: result.thumbnailURL ?? result.imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty:
                        ProgressView()
                            .controlSize(.small)
                    case .failure:
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    @unknown default:
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
            }

            Text(result.sourceHost ?? result.title)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.primary)
            if let dimensionsLabel = result.dimensionsLabel {
                Text(dimensionsLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
    }
}

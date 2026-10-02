import Foundation
import Testing
@testable import whitenoise_ios

struct LinkPreviewTests {
    private let base = URL(string: "https://example.com/articles/one")!

    private func parse(_ html: String) -> LinkPreviewMetadata? {
        LinkPreviewMetadata.parse(html: Data(html.utf8), baseURL: base)
    }

    @Test func readsOpenGraphTitleAndResolvesRelativeImage() throws {
        let metadata = try #require(parse("""
        <html><head>
        <meta property="og:title" content="Tom &amp; Jerry&#39;s &#x201C;Day&#x201D;">
        <meta content='/img/cover.jpg' property='og:image'>
        <title>Fallback</title>
        </head><body></body></html>
        """))
        #expect(metadata.title == "Tom & Jerry's \u{201C}Day\u{201D}")
        #expect(metadata.imageURL == URL(string: "https://example.com/img/cover.jpg"))
    }

    @Test func fallsBackToTwitterThenDocumentTitle() throws {
        let twitter = try #require(parse(#"<head><meta name="twitter:title" content="Tweet title"><title>Doc</title></head>"#))
        #expect(twitter.title == "Tweet title")
        #expect(twitter.imageURL == nil)

        let document = try #require(parse("<head><title>\n  Document   title \n</title></head>"))
        #expect(document.title == "Document title")
    }

    @Test func prefersSecureImageAndRejectsUnsafeImageURLs() throws {
        let secure = try #require(parse("""
        <head>
        <meta property="og:image" content="https://cdn.example.com/plain.png">
        <meta property="og:image:secure_url" content="https://cdn.example.com/secure.png">
        </head>
        """))
        #expect(secure.imageURL == URL(string: "https://cdn.example.com/secure.png"))

        for unsafe in ["http://cdn.example.com/a.png", "https://127.0.0.1/a.png", "https://10.0.0.4/a.png", "javascript:alert(1)", "https://cdn.example.com:8443/a.png"] {
            #expect(parse(#"<head><meta property="og:image" content="\#(unsafe)"></head>"#) == nil)
        }
    }

    @Test func findsMetadataBehindLargeInlineHeadScripts() throws {
        let script = "<script>" + String(repeating: "x", count: 900 * 1024) + "</script>"
        let metadata = try #require(parse(#"<head>\#(script)<meta property="og:image" content="https://i.example.com/v.jpg"></head>"#))
        #expect(metadata.imageURL == URL(string: "https://i.example.com/v.jpg"))
    }

    @Test func ignoresMetadataAfterTheHeadAndReturnsNilWhenEmpty() {
        #expect(parse(#"<head></head><body><meta property="og:title" content="Body"></body>"#) == nil)
        #expect(parse("<html><body>No metadata</body></html>") == nil)
        #expect(parse(#"<head><meta property="og:title" content="   "></head>"#) == nil)
    }

    @Test func boundsAndSanitizesTheTitle() throws {
        let long = String(repeating: "a", count: 1_000)
        let metadata = try #require(parse(#"<head><meta property="og:title" content="\u{202E}\#(long)"></head>"#))
        let title = try #require(metadata.title)
        #expect(title.count == LinkPreviewMetadata.maximumTitleLength)
        #expect(!title.unicodeScalars.contains("\u{202E}"))
    }

    @Test func previewURLPicksTheFirstHTTPSLink() {
        var text = AttributedString("mail http https")
        let mail = text.range(of: "mail")!
        let http = text.range(of: "http ")!
        let https = text.range(of: "https")!
        text[mail].link = URL(string: "mailto:someone@example.com")
        text[http].link = URL(string: "http://insecure.example.com")
        text[https].link = URL(string: "https://secure.example.com/page")

        #expect(LinkPreviewMetadata.previewURL(in: [.paragraph(text)]) == URL(string: "https://secure.example.com/page"))
        #expect(LinkPreviewMetadata.previewURL(in: nil) == nil)
        #expect(LinkPreviewMetadata.previewURL(in: [.codeBlock(AttributedString("https://example.com"))]) == nil)
    }

    @Test func fetchParsesOnlyHTMLResponsesAgainstTheFinalURL() async throws {
        let html = Data(#"<head><meta property="og:image" content="cover.png"></head>"#.utf8)
        let finalURL = URL(string: "https://final.example.com/dir/page")!

        let parsed = try await LinkPreviewLoader.fetchMetadata(for: base) { request in
            #expect(request.httpShouldHandleCookies == false)
            #expect(request.value(forHTTPHeaderField: "Accept")?.hasPrefix("text/html") == true)
            let response = HTTPURLResponse(url: finalURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"])!
            return (html, response)
        }
        #expect(parsed?.imageURL == URL(string: "https://final.example.com/dir/cover.png"))

        let image = try await LinkPreviewLoader.fetchMetadata(for: base) { _ in
            (html, HTTPURLResponse(url: finalURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!)
        }
        #expect(image == nil)
    }

    @Test func fetchNeverContactsUnsafeHosts() async throws {
        for raw in ["http://example.com", "https://localhost/page", "https://192.168.1.1/"] {
            let result = try await LinkPreviewLoader.fetchMetadata(for: URL(string: raw)!) { _ in
                Issue.record("fetched \(raw)")
                throw URLError(.badURL)
            }
            #expect(result == nil)
        }
    }

    @MainActor
    @Test func imageCacheKeySeparatesSizesAndScales() {
        let url = URL(string: "https://cdn.example.com/a.png")!
        let base = LinkPreviewLoader.imageCacheKey(for: url, maxPixelSize: 768, scale: 3)
        #expect(base == LinkPreviewLoader.imageCacheKey(for: url, maxPixelSize: 768, scale: 3))
        #expect(base != LinkPreviewLoader.imageCacheKey(for: url, maxPixelSize: 512, scale: 3))
        #expect(base != LinkPreviewLoader.imageCacheKey(for: url, maxPixelSize: 768, scale: 2))
    }

    @Test func cardHostDropsTheWWWPrefix() {
        #expect(LinkPreviewCardContent.host(for: URL(string: "https://www.example.com/a")!) == "example.com")
        #expect(LinkPreviewCardContent.host(for: URL(string: "https://news.example.com")!) == "news.example.com")
    }

    @MainActor
    @Test func previewsAreOffByDefaultAndPersistTheChoice() throws {
        let suiteName = "LinkPreviewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = LinkPreviewSettingsStore(defaults: defaults)
        #expect(!initial.showsPreviews)

        initial.setShowsPreviews(true)
        #expect(LinkPreviewSettingsStore(defaults: defaults).showsPreviews)
    }
}

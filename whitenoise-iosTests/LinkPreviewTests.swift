import Foundation
import Synchronization
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@Suite(.serialized)
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

    @Test func selectsTheFirstUsableSummaryAndDecodesItsText() throws {
        let metadata = try #require(parse("""
        <head><meta name="description" content="Page text">
        <meta name="twitter:description" content="Fallback text">
        <meta property="og:description" content="  Fish &amp;  chips  "></head>
        """))
        #expect(metadata.summary == "Fish & chips")
        #expect(metadata.title == nil && metadata.imageURL == nil)

        let fallback = try #require(parse("""
        <head><meta property="og:description" content="   ">
        <meta name="description" content="Page description"></head>
        """))
        #expect(fallback.summary == "Page description")
    }

    @Test func boundsRemoteSummaryAndIgnoresBodyMetadata() throws {
        let untrusted = "\u{202E}" + String(repeating: "x", count: 500)
        let metadata = try #require(parse(#"<head><meta name="description" content="\#(untrusted)"></head>"#))
        #expect(metadata.summary == String(repeating: "x", count: 400))
        #expect(parse(#"<head></head><body><meta name="description" content="Unexpected"></body>"#) == nil)
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

    @MainActor
    @Test func markdownImagesNeverTriggerLinkPreviewsWhileExplicitLinksRemainPreviewable() throws {
        func blocks(_ inlines: [MarkdownInlineFfi]) throws -> [MarkdownDisplayBlock] {
            try #require(MarkdownMessageBuilder.displayBlocks(
                for: MarkdownDocumentFfi(blocks: [.paragraph(inlines: inlines)], truncated: false)
            ))
        }

        // Pure markdown image stays tappable/copyable as a link target, but is never previewed.
        let imageOnly = try blocks([
            .image(dest: "https://tracker.example/pixel.png", title: nil, alt: [.text(content: "pixel")], classification: .web),
        ])
        #expect(MessageLinkTarget.targets(in: imageOnly).map(\.copyText) == ["https://tracker.example/pixel.png"])
        #expect(LinkPreviewMetadata.previewURL(in: imageOnly) == nil)

        // Markdown image followed by an explicit link skips the image and previews the explicit link.
        let imageThenLink = try blocks([
            .image(dest: "https://tracker.example/pixel.png", title: nil, alt: [.text(content: "pixel")], classification: .web),
            .text(content: " "),
            .link(dest: "https://article.example/post", title: nil, children: [.text(content: "read")], classification: .web),
        ])
        #expect(LinkPreviewMetadata.previewURL(in: imageThenLink) == URL(string: "https://article.example/post"))

        // Adjacent image + explicit link to the same URL still previews the explicit link.
        let sameURLAdjacent = try blocks([
            .image(dest: "https://same.example/page", title: nil, alt: [.text(content: "img")], classification: .web),
            .link(dest: "https://same.example/page", title: nil, children: [.text(content: "open")], classification: .web),
        ])
        #expect(LinkPreviewMetadata.previewURL(in: sameURLAdjacent) == URL(string: "https://same.example/page"))

        // Linked image uses the explicit outer link destination, so it remains previewable.
        let linkedImage = try blocks([
            .link(
                dest: "https://article.example/post",
                title: nil,
                children: [
                    .image(dest: "https://tracker.example/pixel.png", title: nil, alt: [.text(content: "cover")], classification: .web),
                ],
                classification: .web
            ),
        ])
        #expect(LinkPreviewMetadata.previewURL(in: linkedImage) == URL(string: "https://article.example/post"))
    }

    @MainActor
    @Test func pendingInviteSuppressesMessageBubbleLinkPreviews() throws {
        let blocks = try #require(MarkdownMessageBuilder.displayBlocks(
            for: MarkdownDocumentFfi(
                blocks: [.paragraph(inlines: [.autolink(url: "https://article.example/post", kind: .uri, classification: .web)])],
                truncated: false
            )
        ))

        #expect(MessageBubble.resolvedLinkPreviewURL(
            markdownBlocks: blocks,
            allowsLinkPreviews: false,
            showsLinkPreviews: true
        ) == nil)
        #expect(MessageBubble.resolvedLinkPreviewURL(
            markdownBlocks: blocks,
            allowsLinkPreviews: true,
            showsLinkPreviews: true
        ) == URL(string: "https://article.example/post"))
    }

    @Test func htmlPreviewByteCapIsTighterThanGenericResponseCap() {
        #expect(LinkPreviewLoader.maximumHTMLBytes <= LinkPreviewMetadata.maximumScannedBytes)
        #expect(LinkPreviewLoader.maximumHTMLBytes < RemoteImageFetch.maximumResponseBytes)
    }

    @MainActor
    @Test func loaderBoundsConcurrentFetchesToMaximumConcurrentLoads() async throws {
        let limit = LinkPreviewLoader.maximumConcurrentLoads
        let limiter = CancellableLoadLimiter(maximumConcurrentLoads: limit)
        let entered = (0..<(limit + 1)).map { _ in TestLatch() }
        let release = (0..<(limit + 1)).map { _ in TestLatch() }
        let counts = Mutex<(active: Int, peak: Int, started: Int)>((0, 0, 0))
        let html = Data(#"<head><meta property="og:title" content="Bounded"></head>"#.utf8)

        let urls = try (0..<(limit + 1)).map { index in
            try #require(URL(string: "https://example.com/bounded-\(UUID().uuidString)-\(index)"))
        }

        let tasks = urls.enumerated().map { index, url in
            Task { @MainActor in
                try await LinkPreviewLoader.metadata(
                    for: url,
                    fetch: { request in
                        let slot = counts.withLock { state -> Int in
                            state.active += 1
                            state.peak = max(state.peak, state.active)
                            let current = state.started
                            state.started += 1
                            return current
                        }
                        entered[slot].signal()
                        try await release[slot].wait()
                        counts.withLock { $0.active -= 1 }
                        let response = HTTPURLResponse(
                            url: request.url ?? url,
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: ["Content-Type": "text/html"]
                        )!
                        return (html, response)
                    },
                    limiter: limiter
                )
            }
        }

        for index in 0..<limit {
            try await entered[index].wait()
        }
        // The (limit + 1)-th request must wait behind the limiter until a slot frees up.
        try await eventually {
            await limiter.snapshot() == (active: limit, waiting: 1)
        }
        #expect(!entered[limit].isSignalled)
        #expect(counts.withLock { $0.peak } == limit)

        release[0].signal()
        try await entered[limit].wait()
        for index in 1...limit {
            release[index].signal()
        }

        for task in tasks {
            let metadata = try await task.value
            #expect(metadata?.title == "Bounded")
        }
        #expect(counts.withLock { $0.peak } == limit)
    }

    @MainActor
    @Test func cancellingQueuedCallerPreventsOffscreenPreviewFetchFromStarting() async throws {
        let limiter = CancellableLoadLimiter(maximumConcurrentLoads: 1)
        let activeEntered = TestLatch()
        let activeRelease = TestLatch()
        let queuedFetched = Mutex(false)
        let html = Data(#"<head><meta property="og:title" content="Visible"></head>"#.utf8)
        let visibleURL = try #require(URL(string: "https://example.com/visible-\(UUID().uuidString)"))
        let scrolledOffURL = try #require(URL(string: "https://example.com/scrolled-off-\(UUID().uuidString)"))

        let visibleTask = Task { @MainActor in
            try await LinkPreviewLoader.metadata(
                for: visibleURL,
                fetch: { request in
                    activeEntered.signal()
                    try await activeRelease.wait()
                    let response = HTTPURLResponse(
                        url: request.url ?? visibleURL,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/html"]
                    )!
                    return (html, response)
                },
                limiter: limiter
            )
        }
        try await activeEntered.wait()

        // Queue a second request behind the saturated limiter, then cancel it
        // (simulating a row scrolling off screen) before the first finishes.
        let scrolledOffTask = Task { @MainActor in
            try await LinkPreviewLoader.metadata(
                for: scrolledOffURL,
                fetch: { request in
                    queuedFetched.withLock { $0 = true }
                    let response = HTTPURLResponse(
                        url: request.url ?? scrolledOffURL,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/html"]
                    )!
                    return (html, response)
                },
                limiter: limiter
            )
        }
        try await eventually {
            await limiter.snapshot() == (active: 1, waiting: 1)
        }

        scrolledOffTask.cancel()
        // Release the active permit immediately (before waiting for any MainActor
        // cleanup job) to prove synchronous waiter cancellation prevents the
        // queued request from starting on permit handoff.
        activeRelease.signal()
        do {
            _ = try await scrolledOffTask.value
            Issue.record("Expected cancelled offscreen preview request to throw")
        } catch is CancellationError {
            // Expected.
        }
        let visibleMetadata = try await visibleTask.value
        #expect(visibleMetadata?.title == "Visible")
        #expect(!queuedFetched.withLock { $0 })
    }

    @MainActor
    @Test func clearCachesPreventsInFlightMetadataFromPopulatingCache() async throws {
        let url = URL(string: "https://clear-race-\(UUID().uuidString).example/article")!
        let fetchEntered = TestLatch()
        let fetchRelease = TestLatch()
        let html = Data("<html><head><title>Stale</title></head></html>".utf8)

        let task = Task { @MainActor in
            try? await LinkPreviewLoader.metadata(for: url) { request in
                fetchEntered.signal()
                try? await fetchRelease.wait()
                let response = HTTPURLResponse(
                    url: request.url ?? url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )!
                return (html, response)
            }
        }

        try await fetchEntered.wait()
        LinkPreviewLoader.clearCaches()
        fetchRelease.signal()
        _ = await task.value

        #expect(LinkPreviewLoader.cachedMetadata(for: url) == nil)
    }
}

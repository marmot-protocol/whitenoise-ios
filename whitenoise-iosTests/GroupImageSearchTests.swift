import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

private actor ConcurrentLoadProbe {
    private var active = 0

    func begin() -> Int {
        active += 1
        return active
    }

    func end() {
        active -= 1
    }
}

struct GroupImageSearchTests {
    @Test func groupImageThumbnailLoadsStayWithinConcurrencyLimit() async {
        let limiter = CancellableLoadLimiter(maximumConcurrentLoads: 4)
        let probe = ConcurrentLoadProbe()

        let peak = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    guard let reservation = await limiter.acquire() else { return 0 }
                    let active = await probe.begin()
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    await probe.end()
                    await limiter.release(reservation)
                    return active
                }
            }
            var peak = 0
            for await active in group {
                peak = max(peak, active)
            }
            return peak
        }

        #expect(peak == 4)
    }

    @Test func cancelledThumbnailWaiterResumesAndPreservesPermits() async throws {
        let limiter = CancellableLoadLimiter(maximumConcurrentLoads: 1)
        let first = try #require(await limiter.acquire())
        let queued = Task { await limiter.acquire() }

        while await limiter.snapshot().waiting == 0 {
            await Task.yield()
        }
        queued.cancel()

        #expect(await queued.value == nil)
        #expect(await limiter.snapshot().waiting == 0)
        await limiter.release(first)

        let next = try #require(await limiter.acquire())
        #expect(await limiter.snapshot().active == 1)
        await limiter.release(next)
        // A duplicate release must not mint an extra permit.
        await limiter.release(next)
        #expect(await limiter.snapshot().active == 0)
    }

    @Test func duckDuckGoRequestsCarryBrowserIdentityAndSameOriginReferer() throws {
        let apiURL = try #require(URL(string: "https://duckduckgo.com/i.js?q=cats"))
        let referer = try #require(URL(string: "https://duckduckgo.com/"))

        let request = DuckDuckGoImageSearchClient.request(for: apiURL, referer: referer)

        #expect(request.value(forHTTPHeaderField: "Referer") == "https://duckduckgo.com/")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Mobile/15E148 Safari/604.1") == true)
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.value(forHTTPHeaderField: "Pragma") == "no-cache")
    }

    @Test func duckDuckGoVQDParserHandlesKnownEmbeddings() throws {
        #expect(DuckDuckGoImageSearchClient.vqdToken(in: #"DDG.duckbar.load('images', {vqd:'4-1234567890'});"#) == "4-1234567890")
        #expect(DuckDuckGoImageSearchClient.vqdToken(in: #""vqd":"3-abc&amp;def""#) == "3-abc&def")
        #expect(DuckDuckGoImageSearchClient.vqdToken(in: #"https://duckduckgo.com/i.js?q=cats&vqd=2-token&ia=images"#) == "2-token")
    }

    @Test func duckDuckGoResultDecoderKeepsOnlyPublicHTTPSImages() throws {
        let json = """
        {
          "results": [
            {
              "title": "Safe",
              "image": "https://images.example.com/a.jpg",
              "thumbnail": "//external-content.duckduckgo.com/thumb.jpg",
              "url": "https://example.com/page",
              "width": 640,
              "height": 480
            },
            {
              "title": "Duplicate",
              "image": "https://images.example.com/a.jpg",
              "thumbnail": "https://example.com/other-thumb.jpg",
              "url": "https://example.com/page",
              "width": 640,
              "height": 480
            },
            {
              "title": "Unsafe",
              "image": "http://127.0.0.1/a.jpg",
              "thumbnail": "https://example.com/thumb.jpg",
              "url": "https://example.com/page",
              "width": 1,
              "height": 1
            }
          ]
        }
        """

        let results = try DuckDuckGoImageSearchClient.decodeResults(from: Data(json.utf8))

        #expect(results.count == 1)
        #expect(results.first?.imageURL.absoluteString == "https://images.example.com/a.jpg")
        #expect(results.first?.thumbnailURL?.absoluteString == "https://external-content.duckduckgo.com/thumb.jpg")
        #expect(results.first?.sourceHost == "example.com")
        #expect(results.first?.dimensionsLabel == DuckDuckGoImageSearchClient.dimensionsLabel(
            width: 640,
            height: 480
        ))
    }

    @Test func groupImageDimensionsLabelLocalizesDigits() {
        let locale = Locale(identifier: "ar_EG")

        #expect(DuckDuckGoImageSearchClient.dimensionsLabel(
            width: 640,
            height: 480,
            locale: locale
        ) == L10n.formatted(
            "%@ × %@",
            arguments: [
                LocalizedNumberLabel.decimal(640, locale: locale),
                LocalizedNumberLabel.decimal(480, locale: locale)
            ],
            locale: locale
        ))
        #expect(DuckDuckGoImageSearchClient.dimensionsLabel(
            width: 640,
            height: 480,
            locale: locale
        ) != "640x480")
    }

    @Test func duckDuckGoResultDecoderCapsResultCount() throws {
        let entryCount = DuckDuckGoImageSearchClient.maximumResultCount + 40
        let entries = (0..<entryCount).map { index in
            """
            {
              "title": "Result \(index)",
              "image": "https://images.example.com/\(index).jpg",
              "thumbnail": "https://images.example.com/thumb-\(index).jpg",
              "url": "https://example.com/page/\(index)",
              "width": 640,
              "height": 480
            }
            """
        }.joined(separator: ",\n")
        let json = "{ \"results\": [\n\(entries)\n] }"

        let results = try DuckDuckGoImageSearchClient.decodeResults(from: Data(json.utf8))

        #expect(results.count == DuckDuckGoImageSearchClient.maximumResultCount)
    }

    @Test func duckDuckGoResultDecoderSanitizesAndBoundsFallbackTitle() throws {
        let unsafeTitle = "  Mirror\nHost \u{202E}\u{200B}" + String(
            repeating: "x",
            count: DuckDuckGoImageSearchClient.maximumResultTitleLength + 20
        )
        let resultObject: [String: Any] = [
            "title": unsafeTitle,
            "image": "https://images.example.com/a.jpg",
            "thumbnail": "https://images.example.com/thumb-a.jpg",
            "url": "http://example.com/page",
            "width": 640,
            "height": 480
        ]
        let data = try JSONSerialization.data(withJSONObject: ["results": [resultObject]])

        let results = try DuckDuckGoImageSearchClient.decodeResults(from: data)
        let result = try #require(results.first)

        #expect(result.sourceHost == nil)
        #expect(result.title.count == DuckDuckGoImageSearchClient.maximumResultTitleLength)
        #expect(result.title.hasPrefix("Mirror Host"))
        #expect(!result.title.contains("\n"))
        #expect(!result.title.contains("\u{202E}"))
        #expect(!result.title.contains("\u{200B}"))
    }

    @Test func groupImageDraftMapsToInitialEncryptedImageInput() {
        let draft = GroupImageUploadDraft(
            data: Data([1, 2, 3]),
            mediaType: "image/jpeg",
            sourceURL: "https://images.example/group.jpg",
            dim: "640x480",
            thumbhash: "thumb"
        )

        #expect(draft.initialImage.plaintext == draft.data)
        #expect(draft.initialImage.mediaType == draft.mediaType)
        #expect(draft.initialImage.sourceUrl == nil)
        #expect(draft.initialImage.dim == draft.dim)
        #expect(draft.initialImage.thumbhash == draft.thumbhash)
    }

    @Test func groupImageDraftProcessorNormalizesDeviceImageForUpload() async throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 16)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        }

        let draft = try await GroupImageDraftProcessor.prepare(
            data: png,
            fileName: "group.png",
            typeIdentifier: "public.png"
        )

        #expect(!draft.data.isEmpty)
        #expect(draft.mediaType == "image/jpeg")
        let prepared = try #require(UIImage(data: draft.data)?.cgImage)
        #expect(draft.dim == "\(prepared.width)x\(prepared.height)")
        #expect(draft.initialImage.sourceUrl == nil)
    }

}

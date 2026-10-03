import Foundation
import Testing

@testable import whitenoise_ios

struct GIFPlaybackAdmissionTests {
    @Test func admitsSmallAnimationAndUsesLogicalCanvas() throws {
        let data = Self.container(width: 3, height: 2, frames: [Self.frame(), Self.frame(left: 2, top: 1)])
        #expect(GIFPlaybackAdmission.inspect(data) == .init(width: 3, height: 2, frameCount: 2))
        #expect(try GiphyRemoteMediaLoader.animatedImageAspectRatio(from: data) == 1.5)
    }

    @Test func rejectsLargeCanvasWithTinyPartialFramesBeforeNativeInspection() {
        #expect(GIFPlaybackAdmission.inspect(Self.container(width: 4_097, height: 1)) == nil)
        #expect(GIFPlaybackAdmission.inspect(Self.container(width: 65_535, height: 65_535)) == nil)
        #expect(GIFPlaybackAdmission.inspect(Self.container(width: 0, height: 1)) == nil)
    }

    @Test func boundsEveryFrameRectangle() {
        #expect(GIFPlaybackAdmission.inspect(Self.container(frames: [Self.frame(), Self.frame(width: 2)])) == nil)
        #expect(GIFPlaybackAdmission.inspect(Self.container(frames: [Self.frame(), Self.frame(left: 1)])) == nil)
        #expect(GIFPlaybackAdmission.inspect(Self.container(frames: [Self.frame(), Self.frame(height: 0)])) == nil)
    }

    @Test func enforcesFrameCountAtTheBoundary() {
        let frame = Self.frame()
        #expect(GIFPlaybackAdmission.inspect(Self.container(frames: Array(repeating: frame, count: 1_000))) != nil)
        #expect(GIFPlaybackAdmission.inspect(Self.container(frames: Array(repeating: frame, count: 1_001))) == nil)
    }

    @Test func enforcesAggregateCanvasBudgetWithoutAllocatingPixels() {
        // Eight full logical canvases are exactly 32 Mi pixels; stored frames are 1x1.
        let boundary = Self.container(width: 2_048, height: 2_048, frames: Array(repeating: Self.frame(), count: 8))
        #expect(GIFPlaybackAdmission.inspect(boundary) != nil)
        let over = Self.container(width: 2_048, height: 2_048, frames: Array(repeating: Self.frame(), count: 9))
        #expect(GIFPlaybackAdmission.inspect(over) == nil)
    }

    @Test func boundsOneCanvasIndependentlyOfTotalFrames() {
        #expect(GIFPlaybackAdmission.inspect(Self.container(width: 4_096, height: 1_024)) != nil)
        #expect(GIFPlaybackAdmission.inspect(Self.container(width: 4_096, height: 1_025)) == nil)
    }

    @Test func admitsLoopExtensionAndRejectsReservedFrameFlags() {
        var bytes = Array(Self.container())
        bytes.insert(contentsOf: [0x21, 0xFF, 11] + Array("NETSCAPE2.0".utf8) + [3, 1, 0, 0, 0], at: 13)
        #expect(GIFPlaybackAdmission.inspect(Data(bytes)) != nil)
        var reserved = Array(Self.container())
        reserved[30] |= 0x08  // First image descriptor's reserved flag.
        #expect(GIFPlaybackAdmission.inspect(Data(reserved)) == nil)
    }

    @Test func rejectsEveryIncompletePrefixAndTrailingGarbage() {
        let valid = Self.container()
        for length in 0..<valid.count {
            #expect(GIFPlaybackAdmission.inspect(Data(valid.prefix(length))) == nil)
        }
        #expect(GIFPlaybackAdmission.inspect(valid + Data([0])) == nil)
        #expect(GIFPlaybackAdmission.inspect(Self.container(frames: [Self.frame()])) == nil)
        #expect(GIFPlaybackAdmission.inspect(Data("not a GIF".utf8)) == nil)
    }

    @Test func handlesColorTablesAndBoundedExtensions() {
        let animation = Self.container()
        var bytes = Array(animation)
        bytes[10] = 0x80  // Global two-entry color table.
        bytes.insert(contentsOf: [0, 0, 0, 255, 255, 255], at: 13)
        bytes.insert(contentsOf: [0x21, 0xFE, 3, 65, 66, 67, 0], at: 19)
        #expect(GIFPlaybackAdmission.inspect(Data(bytes)) != nil)
        bytes[21] = 255  // Truncated comment block cannot be skipped past the container.
        #expect(GIFPlaybackAdmission.inspect(Data(bytes)) == nil)
    }

    @Test func rejectsUnsupportedRenderingAndEncodedOverrun() {
        var bytes = Array(Self.container())
        bytes.insert(contentsOf: [0x21, 0x01, 0], at: 13)
        #expect(GIFPlaybackAdmission.inspect(Data(bytes)) == nil)
        #expect(GIFPlaybackAdmission.inspect(Data(count: GiphySearchClient.maximumMediaBytes + 1)) == nil)
    }

    @Test func playbackPreparationCannotBypassAdmissionWithSmallAdvertisedDimensions() async {
        let media = RemoteGiphyMedia(
            url: URL(string: "https://media.giphy.com/media/fixture/giphy.gif")!,
            width: 1, height: 1, attribution: nil)
        let oversizedCanvas = Self.container(width: 4_097, height: 1)
        for _ in 0..<2 {  // A second attempt takes the same admission path.
            do {
                _ = try await GiphyRemoteMediaLoader.preparePlayback(for: media, apiKey: nil) { request in
                    let response = HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "image/gif"]
                    )!
                    return (oversizedCanvas, response)
                }
                Issue.record("Oversized GIF was admitted")
            } catch {
                #expect(error as? GiphyRemoteMediaLoader.Failure == .invalidResponse)
            }
        }
    }

    @Test func playbackPreparationAdmitsACompleteTinyAnimation() async throws {
        let media = RemoteGiphyMedia(
            url: URL(string: "https://media.giphy.com/media/fixture/giphy.gif")!,
            width: 1, height: 1, attribution: nil)
        let data = Self.container(width: 3, height: 2)
        let playback = try await GiphyRemoteMediaLoader.preparePlayback(for: media, apiKey: nil) { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/gif"]
            )!
            return (data, response)
        }
        #expect(playback.data == data)
        #expect(playback.aspectRatio == 1.5)
    }

    @Test func legacyLookupUsesTheSameAdmissionForItsDownloadedGIF() async {
        let media = RemoteGiphyMedia(
            url: URL(string: "https://media.giphy.com/media/fixture/giphy.mp4")!,
            width: 1, height: 1, attribution: nil)
        let lookup = Data(#"{"data":{"id":"fixture","title":"GIF","images":{"original":{"width":"1","height":"1","size":"128","url":"https://media.giphy.com/media/fixture/giphy.gif"}}}}"#.utf8)
        let oversizedCanvas = Self.container(width: 4_097, height: 1)
        let requests = RequestRecorder()
        do {
            _ = try await GiphyRemoteMediaLoader.preparePlayback(for: media, apiKey: "test-key") { request in
                let url = request.url!
                await requests.record(url)
                let isLookup = url.host == "api.giphy.com"
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": isLookup ? "application/json" : "image/gif"]
                )!
                return (isLookup ? lookup : oversizedCanvas, response)
            }
            Issue.record("Legacy lookup admitted an oversized canvas")
        } catch {
            #expect(error as? GiphyRemoteMediaLoader.Failure == .invalidResponse)
        }
        let urls = await requests.urls
        #expect(urls.count == 2)
        #expect(urls.first?.host == "api.giphy.com")
        #expect(urls.last?.pathExtension == "gif")
    }

    /// Hand-assembled complete GIFs keep all rejection tests metadata-only and tiny. The 1x1
    /// LZW payload is a clear code, one pixel, and an end code; no huge raster is constructed.
    private static func container(width: Int = 1, height: Int = 1, frames: [[UInt8]]? = nil) -> Data {
        var bytes = Array("GIF89a".utf8)
        bytes += word(width) + word(height) + [0, 0, 0]
        for frame in frames ?? [Self.frame(), Self.frame()] { bytes += frame }
        bytes.append(0x3B)
        return Data(bytes)
    }

    private static func frame(left: Int = 0, top: Int = 0, width: Int = 1, height: Int = 1) -> [UInt8] {
        // A local color table makes the partial-frame animation valid without a global table.
        [0x21, 0xF9, 4, 0, 10, 0, 0, 0, 0x2C]
            + word(left) + word(top) + word(width) + word(height)
            + [0x80, 0, 0, 0, 255, 255, 255, 2, 2, 0x44, 0x01, 0]
    }

    private static func word(_ value: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }
}

private actor RequestRecorder {
    private(set) var urls: [URL] = []

    func record(_ url: URL) { urls.append(url) }
}

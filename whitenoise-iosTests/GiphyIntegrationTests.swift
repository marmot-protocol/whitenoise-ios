import Foundation
import ImageIO
import MarmotKit
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import whitenoise_ios

struct GiphyIntegrationTests {
    @MainActor
    @Test func animatedGIFViewHasNoIntrinsicPixelSize() {
        let view = GiphyAnimatedImageUIView(frame: .zero)

        #expect(view.intrinsicContentSize.width == UIView.noIntrinsicMetric)
        #expect(view.intrinsicContentSize.height == UIView.noIntrinsicMetric)
        #expect(view.contentCompressionResistancePriority(for: .horizontal) == .defaultLow)
        #expect(view.contentCompressionResistancePriority(for: .vertical) == .defaultLow)
    }

    @Test func decodedGIFGeometrySurvivesPlaybackTeardown() {
        var geometry = StableGiphyDisplayGeometry(fallbackAspectRatio: 1)

        geometry.record(decodedAspectRatio: 16.0 / 9.0)
        let resolvedAspectRatio = geometry.aspectRatio

        // Playback teardown reports no decoded geometry, so the row keeps its
        // resolved size across visibility-driven stop/start.
        geometry.record(decodedAspectRatio: nil)
        #expect(geometry.aspectRatio == resolvedAspectRatio)
        geometry.record(decodedAspectRatio: .nan)
        #expect(geometry.aspectRatio == resolvedAspectRatio)
    }

    @Test func legacyLookupOnlyRetriesTransientResolutionFailure() {
        #expect(GiphySearchClient.shouldRetryLookup(
            error: HostResolutionGuard.GuardError.resolutionFailed,
            retryCount: 0
        ))
        #expect(!GiphySearchClient.shouldRetryLookup(
            error: HostResolutionGuard.GuardError.resolutionFailed,
            retryCount: 2
        ))
        #expect(!GiphySearchClient.shouldRetryLookup(
            error: HostResolutionGuard.GuardError.resolvesToPrivateAddress,
            retryCount: 0
        ))
        #expect(!GiphySearchClient.shouldRetryLookup(
            error: URLError(.badServerResponse),
            retryCount: 0
        ))
    }

    @Test func animatedGIFReadsDimensionsFromItsFirstFrame() throws {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            UTType.gif.identifier as CFString,
            2,
            nil
        ))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: 2,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
        let firstFrame = try #require(context.makeImage())
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
        let secondFrame = try #require(context.makeImage())
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 0.1,
            ],
        ] as CFDictionary
        CGImageDestinationAddImage(destination, firstFrame, frameProperties)
        CGImageDestinationAddImage(destination, secondFrame, frameProperties)
        #expect(CGImageDestinationFinalize(destination))

        let aspectRatio = try GiphyRemoteMediaLoader.animatedImageAspectRatio(from: data as Data)

        #expect(aspectRatio == 2)
    }

    @Test func buildConfigTreatsMissingAndWhitespaceKeysAsUnavailable() {
        #expect(!GiphyBuildConfig.current(infoDictionary: [:]).isAvailable)
        #expect(!GiphyBuildConfig.current(infoDictionary: [
            GiphyBuildConfig.infoDictionaryKey: "  \n",
        ]).isAvailable)
        #expect(GiphyBuildConfig.current(infoDictionary: [
            GiphyBuildConfig.infoDictionaryKey: "  test-key  ",
        ]).apiKey == "test-key")
    }

    @Test func wireTextRoundTripsTheExactGiphyURLAndCredit() throws {
        let url = try #require(URL(string: "https://media1.giphy.com/media/abc/giphy.mp4?cid=client&rid=giphy.mp4"))
        let media = RemoteGiphyMedia(url: url, width: 480, height: 270, attribution: "Creator")

        let parsed = try #require(RemoteGiphyMedia.parse(wireText: media.wireText))

        #expect(parsed.url.absoluteString == url.absoluteString)
        #expect(parsed.attribution == "Creator")
    }

    @Test(arguments: [
        "http://media.giphy.com/media/abc/giphy.mp4",
        "https://giphy.com/media/abc/giphy.mp4",
        "https://media.giphy.com.evil.example/media/abc/giphy.mp4",
        "https://user@media.giphy.com/media/abc/giphy.mp4",
        "https://media.giphy.com:443/media/abc/giphy.mp4",
        "https://media.giphy.com/media/abc/index.html",
    ])
    func rejectsUnsafeOrNonMediaURLs(_ rawURL: String) {
        #expect(RemoteGiphyMedia.validatedMediaURL(rawURL) == nil)
    }

    @Test func wireParserRejectsMalformedMetadata() {
        let url = "https://media.giphy.com/media/abc/giphy.mp4"
        #expect(RemoteGiphyMedia.parse(wireText: url) == nil)
        #expect(RemoteGiphyMedia.parse(wireText: "\(url)\nnot GIPHY") == nil)
        #expect(RemoteGiphyMedia.parse(wireText: "\(url)\nvia GIPHY · \(String(repeating: "a", count: 81))") == nil)
    }

    @Test func captionRidesInTheSameEnvelopeAsTheGIF() throws {
        let media = GiphyDraftFixture.media
        let wireText = try #require(media.captionedWireText("look at this"))

        let parsed = try #require(RemoteGiphyMedia.parse(wireText: wireText))

        #expect(parsed.url == media.url)
        #expect(parsed.attribution == media.attribution)
        #expect(parsed.caption == "look at this")
    }

    @Test func captionSurvivesItsOwnNewlines() throws {
        let wireText = try #require(GiphyDraftFixture.media.captionedWireText("first\nsecond"))

        #expect(RemoteGiphyMedia.parse(wireText: wireText)?.caption == "first\nsecond")
    }

    /// An uncaptioned GIF must stay byte-identical to the pre-caption wire
    /// format so peers that only understand two lines keep rendering it.
    @Test func uncaptionedEnvelopeKeepsTheTwoLineWireFormat() {
        let media = GiphyDraftFixture.media

        #expect(media.uncaptionedWireText == "\(media.url.absoluteString)\nvia GIPHY · Marmot Studio")
        #expect(media.captionedWireText("") == media.uncaptionedWireText)
        #expect(media.captionedWireText("   \n  ") == media.uncaptionedWireText)
    }

    /// Rejecting the envelope over a bad caption would render the raw CDN URL
    /// as message text, so an unusable caption is dropped instead.
    @Test func unusableCaptionDropsTheCaptionRatherThanTheGIF() throws {
        let media = GiphyDraftFixture.media
        let wireText = "\(media.url.absoluteString)\nvia GIPHY\n\u{200B}\u{200B}"

        let parsed = try #require(RemoteGiphyMedia.parse(wireText: wireText))

        #expect(parsed.url == media.url)
        #expect(parsed.caption == nil)
    }

    /// The caption sanitizer bounds its output, so an overlong caption has to
    /// be refused before sanitizing or the tail is silently dropped.
    @Test func captionTooLargeForTheBudgetIsRefusedRatherThanTruncated() throws {
        let media = GiphyDraftFixture.media
        let atLimit = String(repeating: "a", count: RemoteGiphyMedia.maximumCaptionLength)
        let overLimit = String(repeating: "a", count: RemoteGiphyMedia.maximumCaptionLength + 1)

        #expect(media.captionedWireText(overLimit) == nil)
        let fitted = try #require(media.captionedWireText(atLimit))
        #expect(RemoteGiphyMedia.parse(wireText: fitted)?.caption == atLimit)
    }

    @Test func searchRequestKeepsTheQueryAndUsesThePrivacyTransportPolicy() throws {
        let request = try #require(GiphySearchClient.searchRequest(
            query: "tiny cats & dogs",
            apiKey: "test-key",
            locale: Locale(identifier: "pt_PT")
        ))
        let requestURL = try #require(request.url)
        let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(components.scheme == "https")
        #expect(components.host == "api.giphy.com")
        #expect(components.path == "/v1/gifs/search")
        #expect(values["q"] == "tiny cats & dogs")
        #expect(values["api_key"] == "test-key")
        #expect(values["rating"] == "pg-13")
        #expect(values["bundle"] == "messaging_non_clips")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.httpShouldHandleCookies == false)
    }

    @Test func decoderPreservesReturnedMediaURLAndRejectsOversizedRenditions() throws {
        let json = #"""
        {
          "data": [
            {
              "id": "accepted",
              "title": "A GIF",
              "username": "fallback",
              "user": { "username": "creator", "display_name": "Creator Name" },
              "images": {
                "fixed_width": {
                  "width": "480", "height": "270", "size": "4096",
                  "url": "https://media2.giphy.com/media/accepted/giphy.gif?cid=client&rid=giphy.gif",
                  "mp4_size": "2048",
                  "mp4": "https://media2.giphy.com/media/accepted/giphy.mp4?cid=client&rid=giphy.mp4"
                },
                "fixed_width_small_still": {
                  "url": "https://media2.giphy.com/media/accepted/100w.gif?cid=client&rid=100w.gif"
                }
              }
            },
            {
              "id": "too-large",
              "title": "Too large",
              "username": "",
              "images": {
                "fixed_width": {
                  "width": "480", "height": "270", "size": "999999999",
                  "url": "https://media.giphy.com/media/large/giphy.gif",
                  "mp4_size": "1024",
                  "mp4": "https://media.giphy.com/media/large/giphy.mp4"
                },
                "fixed_width_small_still": {
                  "url": "https://media.giphy.com/media/large/100w.gif"
                }
              }
            }
          ]
        }
        """#

        let results = try GiphySearchClient.decodeResults(from: Data(json.utf8))

        #expect(results.count == 1)
        #expect(results.first?.id == "accepted")
        #expect(results.first?.media.url.absoluteString == "https://media2.giphy.com/media/accepted/giphy.gif?cid=client&rid=giphy.gif")
        #expect(results.first?.media.attribution == "Creator Name")
        #expect(results.first?.media.width == 480)
        #expect(results.first?.media.height == 270)
    }

    @Test func decoderPrefersAnimatedImageFromCurrentMessagingBundle() throws {
        let json = #"""
        {
          "data": [{
            "id": "current-bundle",
            "title": "Current bundle",
            "username": "creator",
            "source_tld": "example.com",
            "images": {
              "original": {
                "url": "https://media3.giphy.com/media/current/giphy.gif",
                "width": "480", "height": "270", "size": "681862",
                "mp4_size": "400380",
                "mp4": "https://media3.giphy.com/media/current/giphy.mp4"
              },
              "fixed_width": {
                "url": "https://media3.giphy.com/media/current/200w.gif",
                "width": "200", "height": "113", "mp4_size": "136382",
                "mp4": "https://media3.giphy.com/media/current/200w.mp4"
              },
              "fixed_width_small": {
                "url": "https://media3.giphy.com/media/current/100w.gif",
                "width": "100", "height": "57"
              }
            }
          }]
        }
        """#

        let results = try GiphySearchClient.decodeResults(from: Data(json.utf8))

        #expect(results.count == 1)
        #expect(results.first?.media.url.absoluteString == "https://media3.giphy.com/media/current/giphy.gif")
        #expect(results.first?.media.width == 480)
        #expect(results.first?.media.height == 270)
    }

    @Test func extractsGiphyIDAndBuildsPrivacyPreservingLookupForLegacyMP4Messages() throws {
        let legacyURL = try #require(URL(
            string: "https://media2.giphy.com/media/v1.Y2lkPT/legacy-ID_1/giphy.mp4?cid=client&rid=giphy.mp4"
        ))

        let id = try #require(GiphySearchClient.giphyID(from: legacyURL))
        let request = try #require(GiphySearchClient.lookupRequest(id: id, apiKey: "test-key"))

        #expect(id == "legacy-ID_1")
        #expect(request.url?.host == "api.giphy.com")
        #expect(request.url?.path == "/v1/gifs/legacy-ID_1")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.url?.query?.contains("api_key=test-key") == true)
    }

    @Test func legacyLookupSelectsAnExactAnimatedURLReturnedByGiphy() throws {
        let json = #"""
        {
          "data": {
            "id": "legacy",
            "title": "Legacy",
            "images": {
              "fixed_width": {
                "url": "https://media2.giphy.com/media/legacy/200w.gif?cid=client&rid=200w.gif",
                "width": "200", "height": "113", "size": "250000",
                "mp4": "https://media2.giphy.com/media/legacy/200w.mp4",
                "mp4_size": "100000"
              }
            }
          }
        }
        """#

        let media = try GiphySearchClient.decodeLookupResult(from: Data(json.utf8))

        #expect(media.url.absoluteString == "https://media2.giphy.com/media/legacy/200w.gif?cid=client&rid=200w.gif")
    }

    @Test func decoderPrefersTheLargestAnimatedRenditionUnderTheFastLoadBudget() throws {
        let json = #"""
        {
          "data": [{
            "id": "bounded",
            "title": "Bounded",
            "images": {
              "original": {
                "width": "960", "height": "540", "size": "3145728",
                "url": "https://media.giphy.com/media/bounded/original.gif"
              },
              "downsized": {
                "width": "800", "height": "450", "size": "1800000",
                "url": "https://media.giphy.com/media/bounded/downsized.gif"
              },
              "fixed_height": {
                "width": "640", "height": "360", "size": "800000",
                "url": "https://media.giphy.com/media/bounded/640.gif"
              },
              "fixed_width": {
                "width": "480", "height": "270", "size": "400000",
                "url": "https://media.giphy.com/media/bounded/480.gif"
              }
            }
          }]
        }
        """#

        let result = try #require(GiphySearchClient.decodeResults(from: Data(json.utf8)).first)

        #expect(result.media.url.absoluteString == "https://media.giphy.com/media/bounded/downsized.gif")
        #expect(result.media.width == 800)
        #expect(result.media.height == 450)
    }

    @MainActor
    @Test func automaticLoadingIsOffByDefaultAndPersistsExplicitChoice() throws {
        let suiteName = "GiphyIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = RemoteGIFLoadingStore(defaults: defaults)
        #expect(!initial.automaticallyLoads)

        initial.setAutomaticallyLoads(true)
        let restored = RemoteGIFLoadingStore(defaults: defaults)
        #expect(restored.automaticallyLoads)
    }

    @MainActor
    @Test func playbackBudgetBoundsConcurrentPlayersAndReopensAfterRelease() async throws {
        let budget = GiphyPlaybackBudget(maximumConcurrentPlaybacks: 2)
        let first = try #require(await budget.acquire())
        let second = try #require(await budget.acquire())

        #expect(budget.activePlaybackCount == 2)
        let waiting = Task { await budget.acquire() }
        await Task.yield()

        budget.release(first)
        let third = try #require(await waiting.value)
        #expect(budget.activePlaybackCount == 2)

        budget.release(first)
        #expect(budget.activePlaybackCount == 2)

        budget.release(second)
        budget.release(third)
        #expect(budget.activePlaybackCount == 0)
    }
}

nonisolated enum GiphyDraftFixture {
    static let media = RemoteGiphyMedia(
        url: URL(string: "https://media.giphy.com/media/abc/giphy.gif")!,
        width: 480,
        height: 270,
        attribution: "Marmot Studio"
    )
}

struct GiphyDraftDispatchTests {
    @Test func emptyComposerWithNoGIFDraftSendsNothing() {
        #expect(ConversationSendPreparation.dispatch(
            text: "",
            giphyDraft: nil,
            mediaDrafts: []
        ) == nil)
    }

    @Test func stagedGIFAloneSendsOnlyItsEnvelope() throws {
        let dispatch = try #require(ConversationSendPreparation.dispatch(
            text: "",
            giphyDraft: GiphyDraftFixture.media,
            mediaDrafts: []
        ))

        #expect(dispatch.steps == [.text(GiphyDraftFixture.media.uncaptionedWireText)])
    }

    /// #964 follow-up — a GIF and the text typed with it used to arrive as two
    /// bubbles. One Send is now one message carrying both.
    @Test func stagedGIFCarriesTypedTextInTheSameMessage() throws {
        let dispatch = try #require(ConversationSendPreparation.dispatch(
            text: "look at this",
            giphyDraft: GiphyDraftFixture.media,
            mediaDrafts: []
        ))

        #expect(dispatch.steps.count == 1)
        guard case .text(let body) = try #require(dispatch.steps.first) else {
            Issue.record("expected a single text message")
            return
        }
        let parsed = try #require(RemoteGiphyMedia.parse(wireText: body))
        #expect(parsed.url == GiphyDraftFixture.media.url)
        #expect(parsed.caption == "look at this")
    }

    /// A GIF, a photo, and a caption belong to one message so the caption is no
    /// longer stranded on the photo while the GIF sends separately.
    @Test func stagedGIFSharesOneMessageWithStagedMediaAndCaption() throws {
        let photo = MediaDraftAttachment(
            fileName: "photo.jpg",
            mediaType: "image/jpeg",
            data: Data([0xFF, 0xD8, 0xFF]),
            dim: "100x80"
        )

        let dispatch = try #require(ConversationSendPreparation.dispatch(
            text: "both of these",
            giphyDraft: GiphyDraftFixture.media,
            mediaDrafts: [photo]
        ))

        #expect(dispatch.steps.count == 1)
        guard case .media(let attachments, let caption) = try #require(dispatch.steps.first) else {
            Issue.record("expected a single media message")
            return
        }
        #expect(attachments.map(\.id) == [photo.id])
        #expect(RemoteGiphyMedia.parse(wireText: caption)?.caption == "both of these")
    }

    /// A caption too large for the envelope follows as its own message rather
    /// than being silently truncated away.
    @Test func captionThatCannotFitTheEnvelopeFollowsAsItsOwnMessage() throws {
        let oversized = String(repeating: "a", count: RemoteGiphyMedia.maximumCaptionLength + 1)

        let dispatch = try #require(ConversationSendPreparation.dispatch(
            text: oversized,
            giphyDraft: GiphyDraftFixture.media,
            mediaDrafts: []
        ))

        // The typed text leads so an active reply target stays on what the
        // user wrote instead of moving to the GIF.
        #expect(dispatch.steps == [
            .text(oversized),
            .text(GiphyDraftFixture.media.uncaptionedWireText)
        ])
    }

    @Test func composerWithoutGIFDraftIsUnchanged() throws {
        let dispatch = try #require(ConversationSendPreparation.dispatch(
            text: "plain",
            giphyDraft: nil,
            mediaDrafts: []
        ))

        #expect(dispatch.steps == [.text("plain")])
    }

    /// Editing a GIF works on the caption; the envelope must never reach the
    /// composer and must survive the round trip intact.
    @Test func editingAGIFWorksOnItsCaptionAndKeepsTheEnvelope() throws {
        let media = GiphyDraftFixture.media
        let original = try #require(media.captionedWireText("first"))

        #expect(GiphyMessageEditProjection.editableCaption(for: original) == "first")
        #expect(GiphyMessageEditProjection.editableCaption(for: media.uncaptionedWireText) == "")
        #expect(GiphyMessageEditProjection.editableCaption(for: "plain message") == nil)

        let edited = try #require(GiphyMessageEditProjection.editedPlaintext(
            original: original,
            caption: "second"
        ))
        let parsed = try #require(RemoteGiphyMedia.parse(wireText: edited))
        #expect(parsed.url == media.url)
        #expect(parsed.attribution == media.attribution)
        #expect(parsed.caption == "second")

        #expect(GiphyMessageEditProjection.editedPlaintext(
            original: "plain message",
            caption: "second"
        ) == "second")
        #expect(GiphyMessageEditProjection.editedPlaintext(
            original: original,
            caption: String(repeating: "a", count: RemoteGiphyMedia.maximumCaptionLength + 1)
        ) == nil)
    }

    /// The envelope's URL and credit must never surface as user-facing text in
    /// the bubble or in any preview.
    @Test func capturedGIFTextNeverExposesTheCDNURL() throws {
        let wireText = try #require(GiphyDraftFixture.media.captionedWireText("look at this"))
        let media = try #require(RemoteGiphyMedia.parse(wireText: wireText))

        #expect(MessageBubble.giphyCaptionText(media) == "look at this")
        #expect(MessagePreview.giphyPreview(wireText) == "look at this")
        #expect(MessagePreview.giphyPreview(GiphyDraftFixture.media.uncaptionedWireText) == "GIF via GIPHY")
        #expect(MessageBubble.giphyCaptionText(
            try #require(RemoteGiphyMedia.parse(wireText: GiphyDraftFixture.media.uncaptionedWireText))
        ) == "")
    }

    /// A reply plus typed text plus a GIF is one message, so the reply target
    /// cannot land on the GIF while the typed text goes out detached.
    @Test func gifAndTypedTextNeverSplitWhenTheCaptionFits() throws {
        let dispatch = try #require(ConversationSendPreparation.dispatch(
            text: "haha",
            giphyDraft: GiphyDraftFixture.media,
            mediaDrafts: []
        ))

        #expect(dispatch.steps.count == 1)
    }

    /// A GIF sits inside the visual grid next to photos and videos rather than
    /// stacked above them, but documents and audio keep their own rows.
    @Test func gifJoinsTheGridOnlyWhenEveryAttachmentIsVisual() {
        #expect(MessageGiphyGridPresentation.gridsWithGiphy(isVisualMedia: [true]))
        #expect(MessageGiphyGridPresentation.gridsWithGiphy(isVisualMedia: [true, true, true]))
        #expect(!MessageGiphyGridPresentation.gridsWithGiphy(isVisualMedia: [true, false]))
        #expect(!MessageGiphyGridPresentation.gridsWithGiphy(isVisualMedia: [false]))
        #expect(!MessageGiphyGridPresentation.gridsWithGiphy(isVisualMedia: []))
    }

    /// The GIF occupies a real grid slot, so the layout must size for it.
    @Test func giphyCellCountsTowardTheGridLayout() {
        let gifPlusOnePhoto = MessageMediaGridPresentation.layout(totalCount: 2, maxWidth: 256)
        let onePhotoAlone = MessageMediaGridPresentation.layout(totalCount: 1, maxWidth: 256)

        #expect(gifPlusOnePhoto.frames.count == 2)
        #expect(onePhotoAlone.frames.count == 1)
        #expect(gifPlusOnePhoto.frames[0].width == gifPlusOnePhoto.frames[1].width)
        #expect(gifPlusOnePhoto.overflowCount == 0)
    }

    @Test func giphyCreditLabelCarriesTheAttributionForTheWholeGrid() {
        #expect(GiphyDraftFixture.media.creditLabel
            == L10n.formatted("via GIPHY · %@", "Marmot Studio"))
        #expect(RemoteGiphyMedia(
            url: GiphyDraftFixture.media.url,
            width: 4,
            height: 3,
            attribution: nil
        ).creditLabel == L10n.string("via GIPHY"))
    }

    /// Tapping the GIF opens the gallery on the GIF, and a photo opened from
    /// the same message must still page to it.
    @Test func galleryPagesIncludeTheGIFFromEitherEntryPoint() throws {
        let photo = MessageMediaAttachment(
            id: "owner:aa:1:0",
            reference: nil,
            fileName: "photo.jpg",
            mediaType: "image/jpeg",
            dim: "100x80",
            localData: Data([0xFF, 0xD8, 0xFF]),
            thumbnail: nil
        )
        let media = GiphyDraftFixture.media

        let fromGIF = MessageMediaGallery(giphyMedia: media, items: [photo])
        #expect(fromGIF.pages.map(\.id) == [MessageMediaGallery.giphyPageID, photo.id])
        #expect(fromGIF.initialItemID == MessageMediaGallery.giphyPageID)

        let fromPhoto = try #require(MessageMediaGallery(
            items: [photo],
            initialItem: photo,
            giphyMedia: media
        ))
        #expect(fromPhoto.pages.map(\.id) == [MessageMediaGallery.giphyPageID, photo.id])
        #expect(fromPhoto.initialItemID == photo.id)

        // A colon-free sentinel cannot collide with an "owner:digest:epoch:index" id.
        #expect(!MessageMediaGallery.giphyPageID.contains(":"))
        #expect(photo.id.contains(":"))

        // Galleries without a GIF are unchanged.
        let mediaOnly = try #require(MessageMediaGallery(items: [photo], initialItem: photo))
        #expect(mediaOnly.pages.map(\.id) == [photo.id])
        #expect(mediaOnly.giphyMedia == nil)
    }

    @Test func stagedGIFTileWidthTracksItsAspectRatio() {
        let landscape = ComposerMediaDraftLayout.previewWidth(
            aspectRatio: GiphyDraftFixture.media.aspectRatio
        )
        let square = ComposerMediaDraftLayout.previewWidth(aspectRatio: 1)

        #expect(landscape > square)
        #expect(landscape <= ComposerMediaDraftLayout.maximumPreviewWidth)
        #expect(ComposerMediaDraftLayout.previewWidth(aspectRatio: 0)
            == ComposerMediaDraftLayout.previewWidth(aspectRatio: 1))
        #expect(ComposerMediaDraftLayout.previewWidth(aspectRatio: .nan)
            == ComposerMediaDraftLayout.previewWidth(aspectRatio: 1))
    }
}

struct GiphyDraftPersistenceTests {
    private func snapshot(
        text: String = "",
        media: [MediaDraftAttachment] = [],
        giphy: RemoteGiphyMedia? = GiphyDraftFixture.media
    ) -> ConversationDraftSnapshot {
        ConversationDraftSnapshot(
            canonicalText: text,
            replyToMessageIdHex: nil,
            mediaAttachments: media,
            giphyMedia: giphy
        )
    }

    /// The GIF record is prepended to persistedAttachments, so a full media
    /// strip plus a GIF must not exceed the app's own attachment cap.
    @Test func aStagedGIFReservesOneOfTheAttachmentSlots() {
        let capped = MediaDraftProcessor.maxAttachmentCount

        #expect(ConversationDraftAttachmentBudget.mediaCapacity(hasGiphyDraft: false) == capped)
        #expect(ConversationDraftAttachmentBudget.mediaCapacity(hasGiphyDraft: true) == capped - 1)

        let photos = (0..<ConversationDraftAttachmentBudget.mediaCapacity(hasGiphyDraft: true))
            .map { index in
                MediaDraftAttachment(
                    fileName: "photo\(index).jpg",
                    mediaType: "image/jpeg",
                    data: Data([0xFF, 0xD8, 0xFF]),
                    dim: "100x80"
                )
            }

        #expect(snapshot(media: photos, giphy: GiphyDraftFixture.media)
            .persistedAttachments.count == capped)
    }

    /// A GIF staged next to a photo must stay visible in the chat list rather
    /// than being hidden behind the photo's filename.
    @Test func chatListPreviewCountsAStagedGIFAlongsideMedia() {
        let photo = MediaDraftAttachment(
            fileName: "photo.jpg",
            mediaType: "image/jpeg",
            data: Data([0xFF, 0xD8, 0xFF]),
            dim: "100x80"
        )

        #expect(preview(for: snapshot(media: [photo], giphy: GiphyDraftFixture.media))
            == L10n.plural("📎 %lld attachments", Int64(2)))
        #expect(preview(for: snapshot(giphy: GiphyDraftFixture.media))
            == L10n.string("GIF via GIPHY"))
        #expect(preview(for: snapshot(media: [photo], giphy: nil)) == "📎 photo.jpg")
    }

    private func preview(for snapshot: ConversationDraftSnapshot) -> String? {
        ConversationDraftPreview.text(from: MessageDraftSummaryFfi(
            groupIdHex: "aa",
            content: snapshot.canonicalText,
            replyToMessageIdHex: snapshot.replyToMessageIdHex,
            mediaAttachments: snapshot.persistedAttachmentSummaries,
            createdAtMs: 0,
            updatedAtMs: 0
        ))
    }

    /// A corrupt row must not yield an absurd aspect ratio.
    @Test func outOfRangeGeometryFallsBackToTheParsedPlaceholder() throws {
        let record = try #require(snapshot().persistedAttachments.first)
        let hostile = MessageDraftAttachmentFfi(
            id: record.id,
            fileName: record.fileName,
            mediaType: record.mediaType,
            plaintext: record.plaintext,
            dim: "999999999999x1",
            thumbhash: nil,
            durationSeconds: nil,
            waveformSamples: []
        )

        let restored = try #require(ConversationGiphyDraftRecord.media(from: hostile))

        #expect(restored.width <= RemoteGiphyMedia.maximumDimension)
        #expect(restored.height <= RemoteGiphyMedia.maximumDimension)
        #expect(restored.url == GiphyDraftFixture.media.url)
    }

    @Test func stagedGIFPersistsAsAURLReferenceRatherThanBytes() throws {
        let record = try #require(snapshot().persistedAttachments.first)

        #expect(ConversationGiphyDraftRecord.isRecord(mediaType: record.mediaType))
        #expect(record.plaintext == Data(GiphyDraftFixture.media.wireText.utf8))
        #expect(record.dim == "480x270")
        #expect(String(data: record.plaintext, encoding: .utf8)?
            .contains("media.giphy.com") == true)
    }

    @Test func restoredReferenceKeepsURLAttributionAndGeometry() throws {
        let record = try #require(snapshot().persistedAttachments.first)

        let restored = try #require(ConversationGiphyDraftRecord.media(from: record))

        #expect(restored == GiphyDraftFixture.media)
        #expect(restored.width == 480)
        #expect(restored.height == 270)
        #expect(restored.attribution == "Marmot Studio")
    }

    @Test func partitionKeepsTheReferenceOutOfTheUploadableAttachments() throws {
        let uploadable = MessageDraftAttachmentFfi(
            id: UUID().uuidString,
            fileName: "photo.jpg",
            mediaType: "image/jpeg",
            plaintext: Data([0xFF, 0xD8, 0xFF]),
            dim: "10x10",
            thumbhash: nil,
            durationSeconds: nil,
            waveformSamples: []
        )
        let stored = snapshot(media: []).persistedAttachments + [uploadable]

        let partitioned = ConversationGiphyDraftRecord.partition(stored)

        #expect(partitioned.giphyMedia == GiphyDraftFixture.media)
        #expect(partitioned.media == [uploadable])
        #expect(!partitioned.media.contains {
            ConversationGiphyDraftRecord.isRecord(mediaType: $0.mediaType)
        })
    }

    @Test func hostileOrCorruptReferencesDecodeToNoGIFDraft() {
        func record(plaintext: Data, dim: String? = "480x270") -> MessageDraftAttachmentFfi {
            MessageDraftAttachmentFfi(
                id: ConversationGiphyDraftRecord.recordID,
                fileName: ConversationGiphyDraftRecord.fileName,
                mediaType: ConversationGiphyDraftRecord.mediaType,
                plaintext: plaintext,
                dim: dim,
                thumbhash: nil,
                durationSeconds: nil,
                waveformSamples: []
            )
        }

        #expect(ConversationGiphyDraftRecord.media(from: record(plaintext: Data())) == nil)
        #expect(ConversationGiphyDraftRecord.media(
            from: record(plaintext: Data("https://evil.example/x.gif\nvia GIPHY".utf8))
        ) == nil)
        #expect(ConversationGiphyDraftRecord.media(
            from: record(plaintext: Data("http://media.giphy.com/a.gif\nvia GIPHY".utf8))
        ) == nil)
        #expect(ConversationGiphyDraftRecord.media(
            from: record(plaintext: Data([0xFF, 0xFE, 0xFD]))
        ) == nil)
    }

    @Test func brokenGeometryFallsBackInsteadOfDroppingTheDraft() throws {
        var record = try #require(snapshot().persistedAttachments.first)
        record.dim = "0x0"

        let restored = try #require(ConversationGiphyDraftRecord.media(from: record))

        #expect(restored.url == GiphyDraftFixture.media.url)
        #expect(restored.aspectRatio > 0)
    }

    @Test func aStagedGIFAloneIsAPersistableDraft() throws {
        let stored = snapshot().persistedAttachments

        #expect(stored.count == 1)
        #expect(snapshot(giphy: nil).persistedAttachments.isEmpty)
        #expect(snapshot().persistedAttachmentSummaries.first?.mediaType
            == ConversationGiphyDraftRecord.mediaType)
    }
}

private let giphyEnvelopeURL =
    "https://media3.giphy.com/media/v1.Y2lkPWFjZTYxYTllNTRoMDhkdHg1MGIy/giphy.gif?cid=abc&ct=g"

/// A GIF message must read the same in a notification as in the chat list, and
/// neither surface may render the remote CDN URL as message text — including
/// envelopes this build cannot fully parse: a newer sender's extra lines, a
/// missing or unrecognized credit line, or a preview clipped upstream.
struct GiphyEnvelopePreviewTests {
    private func notificationBody(_ previewText: String) -> String? {
        LocalNotificationProjection.makePresentation(
            for: giphyPreviewUpdate(previewText: previewText)
        )?.body
    }

    private func chatListPreview(_ plaintext: String) -> String {
        MessagePreview.body(
            ChatListMessagePreviewFfi(
                messageIdHex: "01",
                sender: "11",
                senderDisplayName: nil,
                plaintext: plaintext,
                contentTokens: MarkdownDocumentFfi(blocks: [], truncated: false),
                kind: MessageSemantics.kindChat,
                timelineAt: 1,
                deleted: false
            )
        )
    }

    @Test func envelopeShapesWithoutACaptionReadAsTheGIFLabel() throws {
        let shapes = [
            "\(giphyEnvelopeURL)\nvia GIPHY",
            "\(giphyEnvelopeURL)\nvia GIPHY · Creator",
            "\(giphyEnvelopeURL)\nvia TENOR",
            "\(giphyEnvelopeURL)\n",
            "  \(giphyEnvelopeURL)  \nvia GIPHY",
            giphyEnvelopeURL,
            String("\(giphyEnvelopeURL)\nvia GIPHY".prefix(64)),
            String(giphyEnvelopeURL.prefix(48))
        ]

        for shape in shapes {
            #expect(chatListPreview(shape) == "GIF via GIPHY")
            #expect(try #require(notificationBody(shape)) == "Alice: GIF via GIPHY")
        }
    }

    /// A caption is the sender's own words, so it previews the way a photo
    /// caption does. The CDN URL still never reaches preview text.
    @Test func aCaptionedEnvelopeReadsAsItsCaption() throws {
        let captioned = "\(giphyEnvelopeURL)\nvia GIPHY · Creator\nlook at this one"

        #expect(chatListPreview(captioned) == "look at this one")
        #expect(try #require(notificationBody(captioned)) == "Alice: look at this one")
        #expect(!chatListPreview(captioned).contains("giphy.com"))

        // A trailing line that mimics the credit is still only sender text.
        #expect(chatListPreview("\(giphyEnvelopeURL)\nvia GIPHY\n\nvia GIPHY") == "via GIPHY")
    }

    @Test func notificationsAndTheChatListAgreeOnEveryPreview() throws {
        let texts = [
            "\(giphyEnvelopeURL)\nvia GIPHY · Creator\ncaption",
            String(giphyEnvelopeURL.prefix(48)),
            "hello world",
            "look at this \(giphyEnvelopeURL) lol"
        ]

        for text in texts {
            #expect(try #require(notificationBody(text)) == "Alice: \(chatListPreview(text))")
        }
    }

    @Test func textAroundALinkStaysTheSendersOwnWords() {
        // A pasted link inside a sentence is message text, not an envelope, so
        // the preview keeps what the sender wrote.
        #expect(chatListPreview("look at this \(giphyEnvelopeURL) lol")
            == "look at this \(giphyEnvelopeURL) lol")
        #expect(chatListPreview("https://example.com/a.gif") == "https://example.com/a.gif")
        #expect(chatListPreview("https://media.giphy.example.com/a.gif")
            == "https://media.giphy.example.com/a.gif")
    }

    @Test func nonGiphyHostsAndSchemesAreNotEnvelopes() {
        #expect(RemoteGiphyMedia.isEnvelopeText("http://media.giphy.com/a.gif") == false)
        #expect(RemoteGiphyMedia.isEnvelopeText("https://media.giphy.com:8443/a.gif") == false)
        #expect(RemoteGiphyMedia.isEnvelopeText("https://user:pw@media.giphy.com/a.gif") == false)
        #expect(RemoteGiphyMedia.isEnvelopeText("https://giphy.com/gifs/abc") == false)
        #expect(RemoteGiphyMedia.isEnvelopeText("") == false)
    }

    @Test func overlongTextIsNeverClassifiedAsAnEnvelope() {
        let padded = "\(giphyEnvelopeURL)\nvia GIPHY\n"
            + String(repeating: "a", count: RemoteGiphyMedia.maximumWireTextLength)

        #expect(RemoteGiphyMedia.isEnvelopeText(padded) == false)
    }
}

private func giphyPreviewUpdate(previewText: String) -> NotificationUpdateFfi {
    NotificationUpdateFfi(
        notificationKey: "notif-a",
        conversationKey: "conv-a",
        trigger: .newMessage,
        accountRef: "account-a",
        accountIdHex: String(repeating: "11", count: 32),
        groupIdHex: "group-a",
        groupName: nil,
        isDm: false,
        isMention: false,
        messageIdHex: "message-a",
        sender: NotificationUserFfi(
            accountIdHex: String(repeating: "22", count: 32),
            displayName: "Alice",
            pictureUrl: nil
        ),
        receiver: NotificationUserFfi(
            accountIdHex: String(repeating: "11", count: 32),
            displayName: "Me",
            pictureUrl: nil
        ),
        previewText: previewText,
        reactionEmoji: nil,
        reactedToPreview: nil,
        timestampMs: 1_700_000_000_123,
        isFromSelf: false
    )
}

import Foundation
import UIKit
import Testing
@testable import whitenoise_ios

@MainActor
struct OnboardingImageDownloadModelTests {
    private let url = URL(string: "https://example.com/photo.jpg")!

    private func validImageData() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return try #require(image.pngData())
    }

    @Test func undecodableImageFailsInPickerWithoutOpeningCrop() async throws {
        let model = OnboardingImageDownloadModel()
        model.start(url)
        let request = try #require(model.request)
        await model.load(request) { _ in Data("not an image".utf8) }
        #expect(model.request == nil)
        #expect(model.source == nil)
        #expect(model.failure == .unsupported)
    }

    @Test func retryPublishesDownloadedBytesBeforeOpeningCrop() async throws {
        let model = OnboardingImageDownloadModel()
        model.start(url)
        let first = try #require(model.request)
        await model.load(first) { _ in throw URLError(.notConnectedToInternet) }
        #expect(model.request == nil)
        #expect(model.source == nil)
        #expect(model.failure == .connection)

        model.retry()
        let retry = try #require(model.request)
        #expect(retry.id != first.id)
        #expect(retry.url == url)
        #expect(model.failure == nil)
        #expect(model.source == nil)
        let downloadedBytes = try validImageData()
        await model.load(retry) { _ in downloadedBytes }

        #expect(model.request == nil)
        #expect(model.failure == nil)
        #expect(model.source?.data == downloadedBytes)
        #expect(model.source?.preparedImage != nil)
        #expect(model.source?.sourceURL == url)
    }

    @Test func failedRetryStopsLoadingAndOffersAnotherRetry() async throws {
        let model = OnboardingImageDownloadModel()
        model.start(url)
        let first = try #require(model.request)
        await model.load(first) { _ in throw URLError(.timedOut) }

        model.retry()
        let retry = try #require(model.request)
        await model.load(retry) { _ in throw URLError(.networkConnectionLost) }
        #expect(model.request == nil)
        #expect(model.source == nil)
        #expect(model.failure == .connection)

        model.retry()
        #expect(model.request?.url == url)
        #expect(model.request?.id != retry.id)
    }

    @Test(arguments: [false, true])
    func cancelledDownloadCannotReplaceANewerResult(fails: Bool) async throws {
        let model = OnboardingImageDownloadModel()
        model.start(url)
        let old = try #require(model.request)
        let (started, signal) = AsyncStream<Void>.makeStream()
        var completion: CheckedContinuation<Data, any Error>?
        let pending = Task {
            await model.load(old) { _ in
                try await withCheckedThrowingContinuation { continuation in
                    completion = continuation
                    signal.yield(())
                    signal.finish()
                }
            }
        }
        for await _ in started { break }
        model.cancel()
        let nextURL = URL(string: "https://example.com/another.jpg")!
        model.start(nextURL)
        let next = try #require(model.request)
        let newBytes = try validImageData()
        await model.load(next) { _ in newBytes }
        if fails {
            completion?.resume(throwing: URLError(.timedOut))
        } else {
            completion?.resume(returning: Data([4, 5, 6]))
        }
        await pending.value

        #expect(model.request == nil)
        #expect(model.failure == nil)
        #expect(model.source?.sourceURL == nextURL)
        #expect(model.source?.data == newBytes)
    }
}

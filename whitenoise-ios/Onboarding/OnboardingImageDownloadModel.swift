import Foundation
import Observation

@MainActor @Observable
final class OnboardingImageDownloadModel {
    struct Request: Equatable {
        let id = UUID()
        let url: URL
    }

    private(set) var request: Request?
    var source: AvatarImageCropSource?
    var failure: PhotoSelectionFailure?
    private var failedURL: URL?

    func start(_ url: URL) {
        source = nil
        failure = nil
        failedURL = nil
        request = Request(url: url)
    }

    func retry() {
        guard let failedURL else { return }
        start(failedURL)
    }

    func cancel() {
        request = nil
        failure = nil
        failedURL = nil
    }

    func load(_ issued: Request, fetch: @MainActor (URL) async throws -> Data) async {
        guard request?.id == issued.id else { return }
        defer {
            if request?.id == issued.id { request = nil }
        }
        do {
            let data = try await fetch(issued.url)
            try Task.checkCancellation()
            guard request?.id == issued.id else { return }
            let prepared = try await AvatarImageCropSource(
                data: data,
                fileName: issued.url.lastPathComponent,
                typeIdentifier: nil,
                sourceURL: issued.url
            ).prepared()
            guard request?.id == issued.id else { return }
            source = prepared
        } catch {
            guard !Task.isCancelled, request?.id == issued.id else { return }
            failedURL = issued.url
            failure = PhotoSelectionFailure.classify(error, fallback: .download)
        }
    }
}

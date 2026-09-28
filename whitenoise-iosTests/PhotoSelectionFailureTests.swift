import Foundation
import Testing
@testable import whitenoise_ios

struct PhotoSelectionFailureTests {
    @Test func serverAndDownloadFailuresHaveActionableCategories() {
        #expect(PhotoSelectionFailure.classify(PinnedHTTPSFetcher.FetchError.httpStatus(403)) == .denied)
        #expect(PhotoSelectionFailure.classify(PinnedHTTPSFetcher.FetchError.httpStatus(404)) == .missing)
        #expect(PhotoSelectionFailure.classify(PinnedHTTPSFetcher.FetchError.httpStatus(503)) == .download)
        #expect(PhotoSelectionFailure.classify(URLError(.timedOut)) == .connection)
        #expect(PhotoSelectionFailure.classify(URLError(.dataLengthExceedsMaximum)) == .tooLarge)
        #expect(PhotoSelectionFailure.classify(MediaDraftProcessor.Failure.unsupportedImage) == .unsupported)
        #expect(PhotoSelectionFailure.classify(HostResolutionGuard.GuardError.resolvesToPrivateAddress) == .unsafeURL)
        #expect(PhotoSelectionFailure.classify(HostResolutionGuard.GuardError.resolutionFailed) == .connection)
        #expect(!PhotoSelectionFailure.denied.canRetry)
        #expect(!PhotoSelectionFailure.unsupported.canRetry)
        #expect(PhotoSelectionFailure.connection.canRetry)
    }
}

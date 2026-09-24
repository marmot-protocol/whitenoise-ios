import Foundation
import Testing
@testable import whitenoise_ios

struct GroupImageCropRequestTests {
    private let source = AvatarImageCropSource(
        data: Data([0xFF, 0xD8]),
        fileName: "photo.jpg",
        typeIdentifier: "public.jpeg",
        sourceURL: nil
    )

    @Test func loadingRequestHasNoSourceYet() {
        let request = GroupImageCropRequest.loading()

        #expect(request.source == nil)
    }

    @Test func resolvingKeepsTheSamePresentedIdentity() throws {
        let request = GroupImageCropRequest.loading()

        let resolved = try #require(GroupImageCropRequest.resolving(request, requestID: request.id, with: source))

        #expect(resolved.id == request.id)
        #expect(resolved.source?.id == source.id)
    }

    @Test func staleLoadDoesNotReopenADismissedCropper() {
        let dismissed = GroupImageCropRequest.loading()

        #expect(GroupImageCropRequest.resolving(nil, requestID: dismissed.id, with: source) == nil)
    }

    @Test func staleLoadDoesNotReplaceANewerRequest() {
        let older = GroupImageCropRequest.loading()
        let newer = GroupImageCropRequest.loading()

        let result = GroupImageCropRequest.resolving(newer, requestID: older.id, with: source)

        #expect(result?.id == newer.id)
        #expect(result?.source == nil)
    }

    @Test func failureClosesOnlyItsOwnRequest() {
        let older = GroupImageCropRequest.loading()
        let newer = GroupImageCropRequest.loading()

        #expect(GroupImageCropRequest.failing(newer, requestID: newer.id) == nil)
        #expect(GroupImageCropRequest.failing(newer, requestID: older.id)?.id == newer.id)
    }
}

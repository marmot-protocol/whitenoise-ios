import Foundation
import Testing
@testable import whitenoise_ios

struct GroupImageEditTests {
    private let draft = GroupImageUploadDraft(
        data: Data([1, 2, 3]),
        mediaType: "image/jpeg",
        sourceURL: nil,
        dim: nil,
        thumbhash: nil
    )

    @Test func removingAnExistingImageIsAnEdit() {
        #expect(GroupImageEdit.removing(hasCurrentImage: true) == .removed)
    }

    @Test func removingAnUnsavedPickWithoutAnExistingImageRevertsToUnchanged() {
        #expect(GroupImageEdit.removing(hasCurrentImage: false) == .unchanged)
    }

    @Test func hasPhotoFollowsTheEditBeforeTheCurrentImage() {
        #expect(GroupImageEdit.unchanged.hasPhoto(hasCurrentImage: true))
        #expect(!GroupImageEdit.unchanged.hasPhoto(hasCurrentImage: false))
        #expect(GroupImageEdit.replaced(draft).hasPhoto(hasCurrentImage: false))
        #expect(!GroupImageEdit.removed.hasPhoto(hasCurrentImage: true))
    }
}

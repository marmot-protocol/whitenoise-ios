import Foundation
import Testing
@testable import whitenoise_ios

struct WNPhotoSourceRouteTests {

    @Test func devicePhotoSourcesGoBehindTheDisclosureWhenTheImageIsPublished() {
        #expect(
            WNPhotoSourceRoute.route(for: .chooseFromPhotos, confirmsPublicUpload: true)
                == .confirmPublicUpload(.photos)
        )
        #expect(
            WNPhotoSourceRoute.route(for: .chooseFromFiles, confirmsPublicUpload: true)
                == .confirmPublicUpload(.files)
        )
    }

    @Test func devicePhotoSourcesOpenDirectlyWhenNothingLeavesTheDevice() {
        #expect(
            WNPhotoSourceRoute.route(for: .chooseFromPhotos, confirmsPublicUpload: false)
                == .open(.photos)
        )
        #expect(
            WNPhotoSourceRoute.route(for: .chooseFromFiles, confirmsPublicUpload: false)
                == .open(.files)
        )
    }

    @Test func webAndRemovalNeverShowTheUploadDisclosure() {
        for confirms in [true, false] {
            #expect(
                WNPhotoSourceRoute.route(for: .findImageOnWeb, confirmsPublicUpload: confirms) == .web
            )
            #expect(
                WNPhotoSourceRoute.route(for: .removePhoto, confirmsPublicUpload: confirms) == .remove
            )
        }
    }
}

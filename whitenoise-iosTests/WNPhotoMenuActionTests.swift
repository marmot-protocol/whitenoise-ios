import Foundation
import Testing
@testable import whitenoise_ios

struct WNPhotoMenuActionTests {

    @Test func offersOnlySourcesWithoutAPhoto() {
        #expect(
            WNPhotoMenuAction.available(hasPhoto: false)
                == [.chooseFromPhotos, .chooseFromFiles, .findImageOnWeb]
        )
    }

    @Test func appendsRemoveLastWhenAPhotoExists() {
        #expect(
            WNPhotoMenuAction.available(hasPhoto: true)
                == [.chooseFromPhotos, .chooseFromFiles, .findImageOnWeb, .removePhoto]
        )
    }

    @Test func removeIsTheOnlyDestructiveAction() {
        let destructive = WNPhotoMenuAction.allCases.filter(\.isDestructive)
        #expect(destructive == [.removePhoto])
    }

    @Test func everyActionHasASymbol() {
        for action in WNPhotoMenuAction.allCases {
            #expect(!action.systemImage.isEmpty)
        }
    }
}

import Foundation
import Testing
@testable import whitenoise_ios

struct ComposerAttachmentOptionTests {

    @Test func offersEveryDestinationWhenTheDeviceAndBuildSupportThem() {
        #expect(
            ComposerAttachmentOption.available(cameraAvailable: true, gifsAvailable: true)
                == [.camera, .photosAndVideos, .files, .gifs, .location, .contact]
        )
    }

    @Test func dropsCameraOnDevicesWithoutOne() {
        let options = ComposerAttachmentOption.available(cameraAvailable: false, gifsAvailable: true)
        #expect(options == [.photosAndVideos, .files, .gifs, .location, .contact])
    }

    @Test func dropsGifsWhenTheBuildHasNoSearchKey() {
        let options = ComposerAttachmentOption.available(cameraAvailable: true, gifsAvailable: false)
        #expect(options == [.camera, .photosAndVideos, .files, .location, .contact])
    }

    @Test func stillOffersTheDestinationsThatNeedNoCapability() {
        let options = ComposerAttachmentOption.available(cameraAvailable: false, gifsAvailable: false)
        #expect(options == [.photosAndVideos, .files, .location, .contact])
    }

    @Test func keepsOneOrderRegardlessOfWhatIsAvailable() {
        let full = ComposerAttachmentOption.available(cameraAvailable: true, gifsAvailable: true)
        for cameraAvailable in [true, false] {
            for gifsAvailable in [true, false] {
                let options = ComposerAttachmentOption.available(
                    cameraAvailable: cameraAvailable,
                    gifsAvailable: gifsAvailable
                )
                #expect(options == full.filter(options.contains))
            }
        }
    }

    @Test func everyOptionCarriesADistinctSymbol() {
        let symbols = ComposerAttachmentOption.allCases.map(\.systemImage)
        #expect(symbols.allSatisfy { !$0.isEmpty })
        #expect(Set(symbols).count == symbols.count)
    }

    @Test func dropdownRowsMirrorTheAvailableOptions() {
        let items = ComposerAttachmentOption.dropdownItems(cameraAvailable: false, gifsAvailable: true)
        let options = ComposerAttachmentOption.available(cameraAvailable: false, gifsAvailable: true)

        #expect(items.map(\.id) == options)
        #expect(items.map(\.systemImage) == options.map(\.systemImage))
    }

    @Test func dropdownRowsAreUniquelyIdentifiedForForEach() {
        let items = ComposerAttachmentOption.dropdownItems(cameraAvailable: true, gifsAvailable: true)
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test func noAttachmentDestinationIsDestructive() {
        let items = ComposerAttachmentOption.dropdownItems(cameraAvailable: true, gifsAvailable: true)
        #expect(items.allSatisfy { !$0.isDestructive })
    }
}

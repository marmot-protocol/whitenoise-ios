import Testing
import UIKit
@testable import whitenoise_ios

struct AvatarImageCropperTests {
    @Test func undecodableDownloadIsRejected() {
        #expect(AvatarImageCropper.normalizedImage(from: Data("not an image".utf8)) == nil)
    }

    @Test func cropOffsetNeverExposesEmptyCanvas() {
        let offset = AvatarImageCropper.clampedOffset(
            CGSize(width: 500, height: -500),
            imageSize: CGSize(width: 800, height: 400),
            cropSide: 200,
            zoom: 1
        )

        #expect(offset.width == 100)
        #expect(offset.height == 0)
    }

    @Test func squareCropProducesSquareJPEG() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 400, height: 200),
            format: format
        ).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }
        let sourceData = try #require(image.jpegData(compressionQuality: 1))
        let source = try #require(AvatarImageCropper.normalizedImage(from: sourceData))
        let data = try #require(AvatarImageCropper.croppedJPEG(
            image: source,
            cropSide: 200,
            zoom: 1,
            offset: .zero
        ))
        let cropped = try #require(UIImage(data: data))

        #expect(cropped.size.width == cropped.size.height)
        #expect(cropped.size.width == CGFloat(AvatarImageCropper.outputPixelSize))
    }

    @Test func sourceBoundsRejectEmptyOversizedAndExtremePixelInputs() {
        #expect(!AvatarImageCropper.encodedByteCountIsAllowed(0))
        #expect(AvatarImageCropper.encodedByteCountIsAllowed(1))
        #expect(!AvatarImageCropper.encodedByteCountIsAllowed(AvatarImageCropper.maximumEncodedBytes + 1))

        #expect(AvatarImageCropper.sourceDimensionsAreAllowed(width: 8_064, height: 6_048))
        #expect(!AvatarImageCropper.sourceDimensionsAreAllowed(width: 0, height: 100))
        #expect(!AvatarImageCropper.sourceDimensionsAreAllowed(width: 100_000, height: 100_000))
    }

    @Test func boundedFileReadRejectsFileOverConfiguredLimit() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("avatar-byte-cap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x41, count: 9).write(to: url)

        #expect(throws: MediaDraftProcessor.Failure.self) {
            try AvatarImageCropper.boundedFileData(from: url, maximumBytes: 8)
        }
    }

    @Test func editorDecodeDownsamplesBeforeUIKitRendering() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 3_000, height: 1_500),
            format: format
        ).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3_000, height: 1_500))
        }
        let data = try #require(image.jpegData(compressionQuality: 0.8))

        let prepared = try #require(AvatarImageCropper.normalizedImage(from: data))

        #expect(max(prepared.size.width, prepared.size.height) <= CGFloat(AvatarImageCropper.maximumEditorPixelSize))
    }

    @Test func fittedCropSideShrinksForCompactHeightAndCapsElsewhere() {
        #expect(AvatarImageCropper.fittedCropSide(CGSize(width: 393, height: 300))
            == AvatarImageCropper.maximumCropSide)
        #expect(AvatarImageCropper.fittedCropSide(CGSize(width: 874, height: 248)) == 248)
        #expect(AvatarImageCropper.fittedCropSide(CGSize(width: 640, height: 60))
            == AvatarImageCropper.minimumCropSide)
        #expect(AvatarImageCropper.fittedCropSide(.zero) == AvatarImageCropper.minimumCropSide)
    }

    @Test func rescaledOffsetKeepsFramingAcrossCropSideChange() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 400, height: 200),
            format: format
        ).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 200))
        }
        let sourceData = try #require(image.jpegData(compressionQuality: 1))
        let source = try #require(AvatarImageCropper.normalizedImage(from: sourceData))

        let wideOffset = CGSize(width: 60, height: 0)
        let compactOffset = AvatarImageCropper.rescaledOffset(
            wideOffset,
            imageSize: source.size,
            previousCropSide: 300,
            cropSide: 150,
            zoom: 1
        )

        #expect(compactOffset.width == 30)
        #expect(compactOffset.height == 0)

        let wideCrop = try #require(AvatarImageCropper.croppedJPEG(
            image: source,
            cropSide: 300,
            zoom: 1,
            offset: wideOffset
        ))
        let compactCrop = try #require(AvatarImageCropper.croppedJPEG(
            image: source,
            cropSide: 150,
            zoom: 1,
            offset: compactOffset
        ))

        #expect(wideCrop == compactCrop)
    }

    @Test func rescaledOffsetClampsWhenSmallerCropExposesLessImage() {
        let imageSize = CGSize(width: 800, height: 400)
        let rescaled = AvatarImageCropper.rescaledOffset(
            CGSize(width: 400, height: 400),
            imageSize: imageSize,
            previousCropSide: 300,
            cropSide: 150,
            zoom: 1
        )

        #expect(rescaled.width == 75)
        #expect(rescaled.height == 0)
        #expect(AvatarImageCropper.rescaledOffset(
            CGSize(width: 40, height: 0),
            imageSize: imageSize,
            previousCropSide: 0,
            cropSide: 150,
            zoom: 1
        ) == .zero)
    }
}

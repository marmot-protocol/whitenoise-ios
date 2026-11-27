import Testing
@testable import whitenoise_ios

struct MediaSaveDestinationTests {
    @Test(arguments: ["image/jpeg", "image/jpg", "image/png", "image/heic", "image/heif", "image/gif", "IMAGE/PNG; charset=binary"])
    func photoTypesSaveAsPhotos(mimeType: String) {
        #expect(MediaSaveDestination.resource(forMIMEType: mimeType) == .photo)
    }

    @Test(arguments: ["video/mp4", "video/quicktime", "Video/MP4"])
    func videoTypesSaveAsVideos(mimeType: String) {
        #expect(MediaSaveDestination.resource(forMIMEType: mimeType) == .video)
    }

    @Test(arguments: ["image/svg+xml", "audio/mp4", "application/pdf", "text/plain", "video/webm", "", "image/"])
    func otherTypesHaveNoPhotosDestination(mimeType: String) {
        #expect(MediaSaveDestination.resource(forMIMEType: mimeType) == nil)
    }
}

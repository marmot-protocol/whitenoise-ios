import Foundation

nonisolated enum MediaSaveDestination: Equatable, Sendable {
    case photo
    case video

    private static let photoTypes: Set<String> = [
        "image/jpeg", "image/png", "image/heic", "image/heif", "image/gif", "image/webp",
    ]
    private static let videoTypes: Set<String> = [
        "video/mp4", "video/quicktime", "video/x-m4v",
    ]

    static func resource(forMIMEType mimeType: String) -> MediaSaveDestination? {
        let canonical = MediaAttachmentPolicy.canonicalMediaType(mimeType)
        if photoTypes.contains(canonical) { return .photo }
        if videoTypes.contains(canonical) { return .video }
        return nil
    }
}

nonisolated enum MediaSaveFailure: Identifiable, Equatable {
    case photosAccessDenied
    case unsupported

    var id: Self { self }
}

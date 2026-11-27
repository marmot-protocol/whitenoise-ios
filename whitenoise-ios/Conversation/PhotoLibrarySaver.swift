import Foundation
import Photos
import UniformTypeIdentifiers

nonisolated enum PhotoLibrarySaver {
    static func requestAddAccess() async -> Bool {
        switch await PHPhotoLibrary.requestAuthorization(for: .addOnly) {
        case .authorized, .limited: true
        default: false
        }
    }

    static func save(fileURL: URL, as destination: MediaSaveDestination, mimeType: String) async throws {
        let resourceType: PHAssetResourceType = destination == .video ? .video : .photo
        let typeIdentifier = UTType(mimeType: MediaAttachmentPolicy.canonicalMediaType(mimeType))?.identifier
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            options.uniformTypeIdentifier = typeIdentifier
            PHAssetCreationRequest.forAsset().addResource(with: resourceType, fileURL: fileURL, options: options)
        }
    }
}

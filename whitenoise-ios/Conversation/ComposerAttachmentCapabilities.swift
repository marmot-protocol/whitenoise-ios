import UIKit

/// Device and build facts the attachment menu needs. Both are fixed for the
/// life of the process, so they are resolved once instead of from `body`.
@MainActor
enum ComposerAttachmentCapabilities {
    static let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)
    static let gifsAvailable = GiphyBuildConfig.current().isAvailable
}

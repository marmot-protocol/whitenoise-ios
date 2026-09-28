import Foundation

nonisolated enum PhotoSelectionFailure: Error, Equatable, Identifiable {
    case denied, missing, connection, tooLarge, unsupported, unsafeURL, preparation, download, storage

    var id: Self { self }
    var canRetry: Bool { self == .connection || self == .preparation || self == .download || self == .storage }
    var message: String {
        switch self {
        case .denied: L10n.string("This website won’t let us download the image. Choose another image.")
        case .missing: L10n.string("This image is no longer available. Choose another image.")
        case .connection: L10n.string("Couldn’t download the image. Check your connection and try again.")
        case .tooLarge: L10n.string("This image is too large. Choose an image smaller than 25 MB.")
        case .unsupported: L10n.string("We couldn’t read this image. Choose another image.")
        case .unsafeURL: L10n.string("This image link can’t be opened safely. Choose another image.")
        case .storage: L10n.string("Couldn’t save this photo on your device. Free up some space and try again.")
        case .preparation: L10n.string("We couldn’t prepare this photo. Try again.")
        case .download: L10n.string("Couldn’t download this image. Try again or choose another image.")
        }
    }

    static func classify(_ error: Error, fallback: Self = .preparation) -> Self {
        if let failure = error as? Self { return failure }
        if let failure = error as? CocoaError,
           [.fileWriteUnknown, .fileWriteOutOfSpace, .fileWriteNoPermission].contains(failure.code) {
            return .storage
        }
        if let failure = error as? MediaDraftProcessor.Failure {
            switch failure {
            case .attachmentTooLarge: return .tooLarge
            case .unsupportedImage, .unsupportedAttachment: return .unsupported
            case .encodingFailed: return .preparation
            }
        }
        if let failure = error as? HostResolutionGuard.GuardError {
            return failure == .resolvesToPrivateAddress ? .unsafeURL : .connection
        }
        if let failure = error as? PinnedHTTPSFetcher.FetchError {
            switch failure {
            case .httpStatus(401), .httpStatus(403): return .denied
            case .httpStatus(404), .httpStatus(410): return .missing
            case .invalidRequest: return .unsafeURL
            default: return .download
            }
        }
        if let failure = error as? URLError {
            switch failure.code {
            case .dataLengthExceedsMaximum: return .tooLarge
            case .notConnectedToInternet, .timedOut, .networkConnectionLost,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return .connection
            case .redirectToNonExistentLocation, .secureConnectionFailed: return .unsafeURL
            default: return .download
            }
        }
        return fallback
    }
}

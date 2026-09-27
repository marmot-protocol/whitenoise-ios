import AVFoundation

nonisolated enum QRScannerFailure: Equatable {
    case denied, restricted, noCamera, configurationFailed

    enum Recovery: Equatable {
        case settings, retry, none
    }

    var recovery: Recovery {
        switch self {
        case .denied: .settings
        case .configurationFailed: .retry
        case .restricted, .noCamera: .none
        }
    }

    static func preflight(authorization: AVAuthorizationStatus, hasCamera: Bool) -> Self? {
        switch authorization {
        case .denied: .denied
        case .restricted: .restricted
        case .authorized, .notDetermined: hasCamera ? nil : .noCamera
        @unknown default: .configurationFailed
        }
    }
}

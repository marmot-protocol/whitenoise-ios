import AVFoundation

nonisolated enum QRScannerFailure: Equatable {
    case denied, restricted, noCamera, configurationFailed
    case cameraInUse, requiresFullScreen, interrupted

    enum Recovery: Equatable {
        case settings, retry, none
    }

    var recovery: Recovery {
        switch self {
        case .denied: .settings
        case .configurationFailed, .cameraInUse, .requiresFullScreen, .interrupted: .retry
        case .restricted, .noCamera: .none
        }
    }

    static func interruption(reason: Int?) -> Self {
        switch reason.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:)) {
        case .videoDeviceInUseByAnotherClient: .cameraInUse
        case .videoDeviceNotAvailableWithMultipleForegroundApps: .requiresFullScreen
        default: .interrupted
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

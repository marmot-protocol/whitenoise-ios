import SwiftUI

nonisolated enum QRScannerScenePolicy {
    static func mountsCamera(in phase: ScenePhase) -> Bool {
        phase != .background
    }

    static func coversPreview(in phase: ScenePhase) -> Bool {
        phase != .active
    }

    static func restartsScanner(leavingPhase phase: ScenePhase, showingFailure: Bool) -> Bool {
        phase == .background && showingFailure
    }
}

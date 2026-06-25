import UIKit
import CoreHaptics

/// Tiny helper around `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator`.
///
/// All calls are gated on `isSupported`, which is false on the Simulator and
/// on devices without a Taptic Engine (e.g. most iPads). Creating feedback
/// generators where there's no haptic hardware is what produces the
/// "no haptic engine"-style warnings, so we simply never create them there.
enum Haptics {

    /// Whether this device has haptic hardware. Computed once at first use.
    private static let isSupported: Bool =
        CHHapticEngine.capabilitiesForHardware().supportsHaptics

    @MainActor
    static func tap(intensity: CGFloat = 1.0) {
        guard isSupported else { return }
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.prepare()
        gen.impactOccurred(intensity: intensity)
    }

    @MainActor
    static func selection() {
        guard isSupported else { return }
        let gen = UISelectionFeedbackGenerator()
        gen.prepare()
        gen.selectionChanged()
    }

    @MainActor
    static func success() {
        guard isSupported else { return }
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(.success)
    }

    @MainActor
    static func warning() {
        guard isSupported else { return }
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(.warning)
    }

    @MainActor
    static func error() {
        guard isSupported else { return }
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(.error)
    }
}

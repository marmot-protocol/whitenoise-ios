import SwiftUI
import UIKit

@MainActor
enum KeyboardDismissTap {
    /// A tap inside a text input must not resign it, or tapping from one field
    /// straight into another would close the keyboard instead of moving focus.
    static func resignsKeyboard(touching view: UIView?) -> Bool {
        var candidate = view
        while let current = candidate {
            if current is UIControl || current is UITextView { return false }
            candidate = current.superview
        }
        return true
    }
}

/// Includes SwiftUI input padding/accessories, which sit outside the UIKit text field.
final class KeyboardInputRegion: UIView {
    private static let regions = NSHashTable<KeyboardInputRegion>.weakObjects()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { Self.regions.remove(self) }
        else { Self.regions.add(self) }
    }

    static func contains(_ point: CGPoint, in window: UIWindow) -> Bool {
        regions.allObjects.contains { region in
            guard region.window === window,
                  region.bounds.contains(region.convert(point, from: window)) else { return false }
            var ancestor: UIView? = region
            while let view = ancestor {
                if view.isHidden || view.alpha == 0 { return false }
                if view.clipsToBounds, !view.bounds.contains(view.convert(point, from: window)) { return false }
                ancestor = view.superview
            }
            return true
        }
    }
}

private struct KeyboardInputRegionProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyboardInputRegion {
        let view = KeyboardInputRegion()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: KeyboardInputRegion, context: Context) {}
}

private final class KeyboardDismissProbeView: UIView {
    var onWindowChange: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window)
    }
}

private struct KeyboardDismissOnTap: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let probe = KeyboardDismissProbeView()
        probe.isUserInteractionEnabled = false
        let coordinator = context.coordinator
        probe.onWindowChange = { window in
            MainActor.assumeIsolated { coordinator.attach(to: window) }
        }
        return probe
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.attach(to: nil)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var window: UIWindow?

        private lazy var recognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            // Taps still reach rows, menus, and buttons underneath.
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }()

        func attach(to window: UIWindow?) {
            guard window !== self.window else { return }
            self.window?.removeGestureRecognizer(recognizer)
            self.window = window
            window?.addGestureRecognizer(recognizer)
        }

        @objc private func dismissKeyboard() {
            window?.endEditing(true)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard KeyboardDismissTap.resignsKeyboard(touching: touch.view) else { return false }
            guard let window else { return false }
            return !KeyboardInputRegion.contains(touch.location(in: window), in: window)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

extension View {
    func preservesKeyboardOnTap() -> some View {
        background(KeyboardInputRegionProbe())
    }

    func dismissesKeyboardOnTap() -> some View {
        background(KeyboardDismissOnTap())
    }
}

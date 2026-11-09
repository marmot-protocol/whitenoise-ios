import SwiftUI
import UIKit

struct DiagnosticsConsentSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var detent: PresentationDetent = .medium
    @State private var isFinishing = false

    var body: some View {
        NavigationStack {
            DiagnosticsAndImprovementsView(
                isPrompt: true,
                isFinishing: isFinishing,
                onFinish: finish
            )
        }
        .background(DiagnosticsDismissalObserver(onAttempt: finish))
        // A swipe requests completion; it must never dismiss ahead of the consent save.
        .interactiveDismissDisabled()
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onChange(of: dynamicTypeSize, initial: true) {
            if dynamicTypeSize.isAccessibilitySize { detent = .large }
        }
    }

    private func finish() {
        guard !isFinishing, appState.diagnosticsConsent.available,
              appState.diagnosticsConsent.errorMessage == nil else { return }
        isFinishing = true
        Task {
            if await appState.diagnosticsConsent.finishPrompt(using: appState) {
                dismiss()
            } else {
                isFinishing = false
            }
        }
    }
}

/// Observes only this sheet's attempted dismissal, preserving SwiftUI's other
/// presentation delegate callbacks and restoring its delegate on teardown.
private struct DiagnosticsDismissalObserver: UIViewControllerRepresentable {
    var onAttempt: () -> Void

    func makeUIViewController(context: Context) -> ObserverController {
        ObserverController(onAttempt: onAttempt)
    }

    func updateUIViewController(_ controller: ObserverController, context: Context) {
        controller.onAttempt = onAttempt
        controller.attach()
    }

    static func dismantleUIViewController(_ controller: ObserverController, coordinator: ()) {
        controller.onAttempt = {}
        controller.detach()
    }

    final class ObserverController: UIViewController, UISheetPresentationControllerDelegate {
        var onAttempt: () -> Void
        private weak var observedPresentation: UIPresentationController?
        private weak var previousDelegate: (any UIAdaptivePresentationControllerDelegate)?

        init(onAttempt: @escaping () -> Void) {
            self.onAttempt = onAttempt
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Use init(onAttempt:)") }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attach()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            attach()
        }

        func attach() {
            // A child's presentingViewController can resolve through its parent.
            // Attach to the sheet's outer controller, never a navigation child.
            var sheet: UIViewController = self
            while let parent = sheet.parent { sheet = parent }
            guard sheet.presentingViewController != nil,
                  let presentation = sheet.presentationController else { return }
            if observedPresentation !== presentation { detach() }
            if presentation.delegate !== self {
                previousDelegate = presentation.delegate
                observedPresentation = presentation
                presentation.delegate = self
            }
        }

        func detach() {
            if observedPresentation?.delegate === self {
                observedPresentation?.delegate = previousDelegate
            }
            observedPresentation = nil
            previousDelegate = nil
        }

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool { false }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            onAttempt()
        }

        nonisolated override func responds(to selector: Selector?) -> Bool {
            if super.responds(to: selector) { return true }
            // UIKit queries presentation delegates on the main thread.
            return MainActor.assumeIsolated {
                previousDelegate?.responds(to: selector) == true
            }
        }

        nonisolated override func forwardingTarget(for selector: Selector?) -> Any? {
            let delegate = MainActor.assumeIsolated { () -> (any UIAdaptivePresentationControllerDelegate)? in
                previousDelegate?.responds(to: selector) == true ? previousDelegate : nil
            }
            return delegate ?? super.forwardingTarget(for: selector)
        }
    }
}

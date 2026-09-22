import SwiftUI
import UIKit

/// UIKit exposes the source view and arrow control needed by this action sheet.
struct ChatMutePicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var message: String?
    let onSelect: (ChatMuteDuration) -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.picker = self
        controller.updatePresentation()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        let picker = controller.picker
        controller.tearDown()
        Task { @MainActor in picker?.isPresented = false }
    }

    final class Controller: UIViewController, UIAdaptivePresentationControllerDelegate {
        var picker: ChatMutePicker?
        private var alert: UIAlertController?
        private var state = ChatMutePickerState()
        private var selectedDuration: ChatMuteDuration?

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            updatePresentation()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if state.canUpdateAnchor, alert?.isBeingDismissed == false {
                alert?.popoverPresentationController?.sourceRect = view.bounds
            }
            updatePresentation()
        }

        func updatePresentation() {
            guard let picker, picker.isPresented else {
                dismissPicker()
                return
            }
            guard alert == nil, presentedViewController == nil,
                  viewIfLoaded?.window != nil, !view.bounds.isEmpty,
                  state.beginPresentation() else { return }

            let alert = UIAlertController(
                title: L10n.string("Mute Notifications"),
                message: picker.message,
                preferredStyle: .actionSheet
            )
            for duration in ChatMuteDuration.allCases {
                alert.addAction(UIAlertAction(title: duration.title, style: .default) { [weak self] _ in
                    self?.select(duration)
                })
            }
            alert.addAction(UIAlertAction(title: L10n.string("Cancel"), style: .cancel) { [weak self] _ in
                self?.dismissPicker()
            })
            if let popover = alert.popoverPresentationController {
                popover.sourceView = view
                popover.sourceRect = view.bounds
                popover.permittedArrowDirections = []
            }
            self.alert = alert
            alert.presentationController?.delegate = self
            present(alert, animated: true)
        }

        func dismissPicker() {
            guard state.beginDismissal() else { return }
            completeDismissal()
        }

        private func select(_ duration: ChatMuteDuration) {
            guard state.beginDismissal() else { return }
            selectedDuration = duration
            completeDismissal()
        }

        private func completeDismissal() {
            guard let alert, alert.presentingViewController != nil else {
                finishDismissal()
                return
            }
            // An alert action may already have started UIKit's dismissal.
            if alert.isBeingDismissed, let transition = alert.transitionCoordinator,
               transition.animate(alongsideTransition: nil, completion: { [weak self] _ in
                   self?.finishDismissal()
               }) {
                return
            }
            alert.dismiss(animated: true) { [weak self] in
                self?.finishDismissal()
            }
        }

        private func finishDismissal() {
            guard state.finish() else { return }
            alert = nil
            let duration = selectedDuration
            selectedDuration = nil
            guard let picker else { return }
            // Removing the row's presenter is safe only after UIKit finishes.
            if let duration, picker.isPresented { picker.onSelect(duration) }
            picker.isPresented = false
        }

        func tearDown() {
            picker = nil
            selectedDuration = nil
            _ = state.finish()
            alert?.dismiss(animated: false)
            alert = nil
        }

        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            guard state.beginDismissal() else { return }
            presentationController.presentedViewController.transitionCoordinator?
                .notifyWhenInteractionChanges { [weak self] context in
                    if context.isCancelled { self?.state.cancelInteractiveDismissal() }
                }
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            finishDismissal()
        }
    }
}

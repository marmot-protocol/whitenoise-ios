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
        controller.picker = nil
        controller.dismissPicker()
        Task { @MainActor in picker?.isPresented = false }
    }

    final class Controller: UIViewController, UIAdaptivePresentationControllerDelegate {
        var picker: ChatMutePicker?
        private var alert: UIAlertController?

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
            alert?.popoverPresentationController?.sourceRect = view.bounds
            updatePresentation()
        }

        func updatePresentation() {
            guard let picker, picker.isPresented else {
                dismissPicker()
                return
            }
            guard alert == nil, presentedViewController == nil,
                  viewIfLoaded?.window != nil, !view.bounds.isEmpty else { return }

            let alert = UIAlertController(
                title: L10n.string("Mute Notifications"),
                message: picker.message,
                preferredStyle: .actionSheet
            )
            for duration in ChatMuteDuration.allCases {
                alert.addAction(UIAlertAction(title: duration.title, style: .default) { [weak self] _ in
                    self?.alert = nil
                    picker.onSelect(duration)
                    picker.isPresented = false
                })
            }
            alert.addAction(UIAlertAction(title: L10n.string("Cancel"), style: .cancel) { [weak self] _ in
                self?.alert = nil
                picker.isPresented = false
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
            guard let alert else { return }
            self.alert = nil
            alert.dismiss(animated: true)
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            alert = nil
            picker?.isPresented = false
        }
    }
}

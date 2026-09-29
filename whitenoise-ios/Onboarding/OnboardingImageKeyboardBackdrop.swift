import SwiftUI
import UIKit

struct OnboardingImageKeyboardBackdrop: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        OnboardingImageKeyboardBackdropView()
    }

    func updateUIView(
        _ uiView: UIView,
        context: Context
    ) {}
}

private final class OnboardingImageKeyboardBackdropView: UIView {
    private let backdropView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        backdropView.translatesAutoresizingMaskIntoConstraints = false
        backdropView.backgroundColor = .systemGroupedBackground
        backdropView.isUserInteractionEnabled = false
        addSubview(backdropView)

        NSLayoutConstraint.activate([
            backdropView.topAnchor.constraint(
                equalTo: keyboardLayoutGuide.topAnchor
            ),
            backdropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let keyboardIsVisible = keyboardLayoutGuide.layoutFrame.minY
            < safeAreaLayoutGuide.layoutFrame.maxY
        backdropView.isHidden = !keyboardIsVisible
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

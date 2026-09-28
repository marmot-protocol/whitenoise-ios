import SwiftUI
import UIKit

struct OnboardingImageSearchBar: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UISearchBar {
        let searchBar = UISearchBar()
        searchBar.delegate = context.coordinator
        searchBar.searchBarStyle = .minimal
        searchBar.placeholder = L10n.string("Search Images")
        searchBar.showsCancelButton = false
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.searchTextField.clearButtonMode = .never
        searchBar.searchTextField.returnKeyType = .search
        return searchBar
    }

    func updateUIView(_ uiView: UISearchBar, context: Context) {
        context.coordinator.parent = self

        if uiView.text != text {
            uiView.text = text
        }
        uiView.searchTextField.clearButtonMode = text.isEmpty ? .never : .always

        if isFocused, !uiView.searchTextField.isFirstResponder {
            uiView.searchTextField.becomeFirstResponder()
        } else if !isFocused, uiView.searchTextField.isFirstResponder {
            uiView.searchTextField.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UISearchBarDelegate {
        var parent: OnboardingImageSearchBar

        init(parent: OnboardingImageSearchBar) {
            self.parent = parent
        }

        func searchBar(
            _ searchBar: UISearchBar,
            textDidChange searchText: String
        ) {
            parent.text = searchText
        }

        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            parent.isFocused = true
        }

        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            parent.isFocused = false
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            parent.isFocused = false
            searchBar.searchTextField.resignFirstResponder()
        }
    }
}

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

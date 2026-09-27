import SwiftUI
import UIKit

struct WNZoomableContent<Content: View>: UIViewRepresentable {
    let naturalSize: CGSize
    let accessibilityLabel: String
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> UIHostingController<AnyView> {
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.view.backgroundColor = .clear
        return host
    }

    func makeUIView(context: Context) -> WNZoomScrollView {
        WNZoomScrollView(zoomedView: context.coordinator.view)
    }

    func updateUIView(_ view: WNZoomScrollView, context: Context) {
        context.coordinator.rootView = AnyView(content().environment(\.self, context.environment))
        view.accessibilityLabel = accessibilityLabel
        if view.naturalContentSize != naturalSize { view.naturalContentSize = naturalSize }
    }
}

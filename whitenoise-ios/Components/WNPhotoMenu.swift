import SwiftUI

/// One row of the avatar photo menu. `available(hasPhoto:)` is the whole
/// decision the menu makes, so it stays testable without a view.
nonisolated enum WNPhotoMenuAction: Hashable, CaseIterable {
    case chooseFromPhotos
    case chooseFromFiles
    case findImageOnWeb
    case removePhoto

    static func available(hasPhoto: Bool) -> [Self] {
        var actions: [Self] = [.chooseFromPhotos, .chooseFromFiles, .findImageOnWeb]
        if hasPhoto { actions.append(.removePhoto) }
        return actions
    }

    var title: LocalizedStringKey {
        switch self {
        case .chooseFromPhotos: "Choose from Photos"
        case .chooseFromFiles: "Choose from Files"
        case .findImageOnWeb: "Find Image on Web"
        case .removePhoto: "Remove Photo"
        }
    }

    var systemImage: String {
        switch self {
        case .chooseFromPhotos: "photo.on.rectangle"
        case .chooseFromFiles: "folder"
        case .findImageOnWeb: "globe"
        case .removePhoto: "trash"
        }
    }

    var isDestructive: Bool {
        self == .removePhoto
    }
}

nonisolated enum WNPhotoMenuMetrics {
    static let rowHeight: CGFloat = 44
    static let menuWidth: CGFloat = 250
    static let cornerRadius: CGFloat = 14
    static let anchorGap: CGFloat = 6
    static let screenMargin: CGFloat = 16

    static func panelHeight(hasPhoto: Bool) -> CGFloat {
        let actions = WNPhotoMenuAction.available(hasPhoto: hasPhoto)
        let dividers = actions.filter(\.isDestructive).count
        return CGFloat(actions.count) * rowHeight + CGFloat(dividers)
    }

    /// Places the panel under `anchor`, centered on it, kept inside `container`
    /// and flipped above the anchor when it would not fit below. A container
    /// too small to lay the panel out is treated as unbounded, so the panel
    /// still lands next to its button rather than in a corner.
    static func panelOrigin(
        anchor: CGRect,
        panelHeight: CGFloat,
        container: CGSize
    ) -> CGPoint {
        let centered = anchor.midX - menuWidth / 2
        let below = anchor.maxY + anchorGap
        guard container.width > menuWidth, container.height > panelHeight else {
            return CGPoint(x: max(centered, 0), y: below)
        }

        let lastX = max(screenMargin, container.width - menuWidth - screenMargin)
        let x = min(max(centered, screenMargin), lastX)
        let fitsBelow = below + panelHeight + screenMargin <= container.height
        let above = anchor.minY - anchorGap - panelHeight
        let y = fitsBelow ? below : max(screenMargin, above)
        return CGPoint(x: x, y: y)
    }
}

nonisolated struct WNPhotoMenuAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// The "Add Photo" / "Change Photo" trigger shared by Sign Up and Profile.
///
/// The panel it opens is drawn by `wnPhotoMenu(isPresented:hasPhoto:onSelect:)`
/// on the enclosing form, not here: a `Form` row clips anything that extends
/// past it, and a presentation would have to reconcile coordinate spaces that
/// differ between a plain form and one inside a sheet. Publishing an anchor
/// upward keeps the panel in the form's own space, so both screens agree.
struct WNPhotoMenuButton: View {
    let hasPhoto: Bool
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Text(hasPhoto ? "Change Photo" : "Add Photo")
        }
        .wnAvatarActionButtonStyle()
        .anchorPreference(key: WNPhotoMenuAnchorKey.self, value: .bounds) { $0 }
    }
}

extension View {
    /// Draws the photo menu panel over this container, anchored to the
    /// `WNPhotoMenuButton` inside it. Apply outside any `disabled` the form
    /// carries, so the panel's own rows stay tappable.
    func wnPhotoMenu(
        isPresented: Binding<Bool>,
        hasPhoto: Bool,
        onSelect: @escaping (WNPhotoMenuAction) -> Void
    ) -> some View {
        modifier(
            WNPhotoMenuOverlay(
                isPresented: isPresented,
                hasPhoto: hasPhoto,
                onSelect: onSelect
            )
        )
    }
}

private struct WNPhotoMenuOverlay: ViewModifier {
    @Binding var isPresented: Bool
    let hasPhoto: Bool
    let onSelect: (WNPhotoMenuAction) -> Void

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(WNPhotoMenuAnchorKey.self) { anchor in
                GeometryReader { proxy in
                    if isPresented, let anchor {
                        panel(anchor: proxy[anchor], container: proxy.size)
                    }
                }
                .animation(.easeOut(duration: 0.16), value: isPresented)
            }
    }

    private func panel(anchor: CGRect, container: CGSize) -> some View {
        let origin = WNPhotoMenuMetrics.panelOrigin(
            anchor: anchor,
            panelHeight: WNPhotoMenuMetrics.panelHeight(hasPhoto: hasPhoto),
            container: container
        )

        return ZStack(alignment: .topLeading) {
            Button {
                isPresented = false
            } label: {
                Color.clear.contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")

            WNPhotoMenuPanel(hasPhoto: hasPhoto) { action in
                isPresented = false
                onSelect(action)
            }
            .offset(x: origin.x, y: origin.y)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        }
    }
}

private struct WNPhotoMenuPanel: View {
    let hasPhoto: Bool
    let onSelect: (WNPhotoMenuAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(WNPhotoMenuAction.available(hasPhoto: hasPhoto), id: \.self) { action in
                if action.isDestructive {
                    Divider()
                }

                WNPhotoMenuRow(action: action) {
                    onSelect(action)
                }
            }
        }
        .frame(width: WNPhotoMenuMetrics.menuWidth)
        .background(.regularMaterial, in: .rect(cornerRadius: WNPhotoMenuMetrics.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: WNPhotoMenuMetrics.cornerRadius)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }
}

private struct WNPhotoMenuRow: View {
    let action: WNPhotoMenuAction
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Label(action.title, systemImage: action.systemImage)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .frame(height: WNPhotoMenuMetrics.rowHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(action.isDestructive ? Color.red : Color.primary)
    }
}

#Preview("WNPhotoMenu") {
    @Previewable @State var isPresented = false

    Form {
        Section {
            VStack {
                Circle().fill(.gray).frame(width: 120, height: 120)
                WNPhotoMenuButton(hasPhoto: true, isPresented: $isPresented)
                    .padding(.top)
            }
            .frame(maxWidth: .infinity)
        }
    }
    .wnPhotoMenu(isPresented: $isPresented, hasPhoto: true) { _ in }
}

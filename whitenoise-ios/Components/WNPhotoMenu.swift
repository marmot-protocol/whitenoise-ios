import SwiftUI
import UIKit

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

    func symbol(for colorScheme: ColorScheme, contrast: ColorSchemeContrast = .standard) -> UIImage {
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light),
            UITraitCollection(accessibilityContrast: contrast == .increased ? .high : .normal)
        ])
        let color = (isDestructive ? UIColor.systemRed : .label).resolvedColor(with: traits)
        return UIImage(systemName: systemImage)?.withTintColor(color, renderingMode: .alwaysOriginal) ?? UIImage()
    }
}

struct WNPhotoMenuButton: View {
    let hasPhoto: Bool
    @Binding var selection: WNPhotoMenuAction?

    var body: some View {
        Menu {
            WNPhotoMenuActions(hasPhoto: hasPhoto, selection: $selection)
        } label: {
            Text(hasPhoto ? "Change Photo" : "Add Photo")
        }
        .wnAvatarActionButtonStyle()
    }
}

struct WNPhotoMenuActions: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    let hasPhoto: Bool
    @Binding var selection: WNPhotoMenuAction?

    var body: some View {
        ForEach(WNPhotoMenuAction.available(hasPhoto: hasPhoto), id: \.self) { action in
            if action.isDestructive {
                Divider()
            }
            Button(role: action.isDestructive ? .destructive : nil) {
                selection = action
            } label: {
                Label {
                    Text(action.title)
                } icon: {
                    Image(uiImage: action.symbol(for: colorScheme, contrast: contrast))
                }
            }
        }
    }
}

#Preview("WNPhotoMenu") {
    @Previewable @State var selection: WNPhotoMenuAction?

    WNPhotoMenuButton(hasPhoto: true, selection: $selection)
}

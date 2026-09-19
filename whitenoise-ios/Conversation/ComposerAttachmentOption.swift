import SwiftUI

/// The destinations the composer's `+` button offers.
///
/// `available(cameraAvailable:gifsAvailable:)` is the whole decision the menu
/// makes, so it stays assertable without a view. Declaration order is the
/// presented order.
nonisolated enum ComposerAttachmentOption: String, CaseIterable, Hashable {
    case camera
    case photosAndVideos
    case files
    case gifs
    case location
    case contact

    static func available(cameraAvailable: Bool, gifsAvailable: Bool) -> [Self] {
        allCases.filter { option in
            switch option {
            case .camera: cameraAvailable
            case .gifs: gifsAvailable
            default: true
            }
        }
    }

    static func dropdownItems(
        cameraAvailable: Bool,
        gifsAvailable: Bool
    ) -> [WNDropdownItem<Self>] {
        available(cameraAvailable: cameraAvailable, gifsAvailable: gifsAvailable)
            .map(\.dropdownItem)
    }

    var dropdownItem: WNDropdownItem<Self> {
        WNDropdownItem(id: self, title: title, systemImage: systemImage)
    }

    var title: LocalizedStringKey {
        switch self {
        case .camera: "Camera"
        case .photosAndVideos: "Photos and Videos"
        case .files: "Files"
        case .gifs: "GIFs"
        case .location: "Location"
        case .contact: "Contact"
        }
    }

    var systemImage: String {
        switch self {
        case .camera: "camera"
        case .photosAndVideos: "photo.on.rectangle.angled"
        case .files: "folder"
        case .gifs: "rectangle.stack.badge.play"
        case .location: "location"
        case .contact: "person.crop.circle"
        }
    }
}

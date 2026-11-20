import UIKit

/// Wording that names this device's kind ("this iPhone", "this iPad").
enum LinkThisDeviceCopy {
    private static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// The default name for this device: "iPhone" or "iPad".
    static var defaultDeviceName: String { UIDevice.current.model }

    static var thisDeviceNameLabel: String {
        isPad ? L10n.string("This iPad’s name") : L10n.string("This iPhone’s name")
    }

    static var nameThisDeviceTitle: String {
        isPad ? L10n.string("Name This iPad") : L10n.string("Name This iPhone")
    }

    static var action: String {
        isPad ? L10n.string("Link This iPad") : L10n.string("Link This iPhone")
    }

    static var offer: String {
        isPad
            ? L10n.string("Link this iPad to your other device to bring your chats here.")
            : L10n.string("Link this iPhone to your other device to bring your chats here.")
    }

    /// The one line the setup step adds in a device-group build. A note, not an
    /// action: linking needs the KeyPackage that setup publishes after this step.
    static var setupNote: String {
        isPad
            ? L10n.string("When setup finishes, you can link this iPad to your other device.")
            : L10n.string("When setup finishes, you can link this iPhone to your other device.")
    }
}

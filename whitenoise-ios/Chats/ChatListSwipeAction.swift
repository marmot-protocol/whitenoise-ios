import SwiftUI

/// One chat-list swipe control, drawn as a bare glyph. A swipe button that
/// carries no title is what makes UIKit round it on iOS 26, so `title` is an
/// accessibility name only and must never reach a `Text`. Archive and
/// unarchive deliberately share a glyph — they never appear in the same list —
/// which is why every case has to keep a distinct title.
nonisolated enum ChatListSwipeAction: String, CaseIterable, Identifiable, Sendable {
    case read
    case unread
    case pin
    case unpin
    case mute
    case unmute
    case archive
    case unarchive
    case leave
    case delete

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .read: "message.fill"
        case .unread: "message.badge"
        case .pin: "pin.fill"
        case .unpin: "pin.slash.fill"
        case .mute: "bell.slash.fill"
        case .unmute: "bell.fill"
        case .archive, .unarchive: "archivebox.fill"
        case .leave: "rectangle.portrait.and.arrow.right"
        case .delete: "trash.fill"
        }
    }

    var tint: Color {
        switch self {
        case .read, .unread: .blue
        case .pin, .unpin: .orange
        case .mute, .unmute: .indigo
        case .archive, .unarchive: .gray
        case .leave, .delete: .red
        }
    }

    var title: String {
        switch self {
        case .read: L10n.string("Mark as read")
        case .unread: L10n.string("Mark as unread")
        case .pin: L10n.string("Pin")
        case .unpin: L10n.string("Unpin")
        case .mute: L10n.string("Mute")
        case .unmute: L10n.string("Unmute")
        case .archive: L10n.string("Archive")
        case .unarchive: L10n.string("Unarchive")
        case .leave: L10n.string("Leave")
        case .delete: L10n.string("Delete")
        }
    }
}

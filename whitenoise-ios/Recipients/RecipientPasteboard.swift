import Foundation

/// Clipboard text on its way into a recipient search field.
nonisolated enum RecipientPasteboard {
    /// An `nprofile` carrying relay hints stays well under this, so anything
    /// longer is a document rather than a profile reference.
    static let maxLength = 1024

    static func profileQuery(from raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.count <= maxLength
        else { return nil }
        return trimmed
    }
}

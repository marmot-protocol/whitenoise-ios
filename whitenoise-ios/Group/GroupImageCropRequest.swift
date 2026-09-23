import Foundation

nonisolated struct GroupImageCropRequest: Identifiable {
    let id: UUID
    private(set) var source: AvatarImageCropSource?

    static func loading() -> Self {
        Self(id: UUID(), source: nil)
    }

    static func resolving(
        _ current: Self?,
        requestID: UUID,
        with source: AvatarImageCropSource
    ) -> Self? {
        guard var current, current.id == requestID else { return current }
        current.source = source
        return current
    }

    static func failing(_ current: Self?, requestID: UUID) -> Self? {
        guard let current, current.id == requestID else { return current }
        return nil
    }
}

import Foundation

nonisolated enum GroupImageEdit: Equatable {
    case unchanged
    case replaced(GroupImageUploadDraft)
    case removed

    static func removing(hasCurrentImage: Bool) -> Self {
        hasCurrentImage ? .removed : .unchanged
    }

    func hasPhoto(hasCurrentImage: Bool) -> Bool {
        switch self {
        case .unchanged: hasCurrentImage
        case .replaced: true
        case .removed: false
        }
    }
}

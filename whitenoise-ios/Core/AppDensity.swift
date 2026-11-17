import SwiftUI

/// How tightly the chat list and the conversation timeline pack their rows.
/// Density changes spacing only; text size stays with Dynamic Type, and native
/// forms keep the system's row metrics and touch targets.
nonisolated enum AppDensity: String, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    case comfortable

    static let storageKey = "appearance.density"

    static func resolved(rawValue: String?) -> AppDensity {
        rawValue.flatMap(AppDensity.init(rawValue:)) ?? .standard
    }

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .compact: "Compact"
        case .standard: "Standard"
        case .comfortable: "Comfortable"
        }
    }

    var metrics: AppDensityMetrics {
        switch self {
        case .compact: .compact
        case .standard: .standard
        case .comfortable: .comfortable
        }
    }
}

nonisolated struct AppDensityMetrics: Equatable, Sendable {
    /// Inset above and below each chat-list row.
    let chatRowVerticalInset: CGFloat
    let chatRowAvatarSize: CGFloat
    /// Gap between the avatar and the row's text.
    let chatRowAvatarSpacing: CGFloat
    /// Gap between the title line and the preview.
    let chatRowLineSpacing: CGFloat
    /// Preview lines below accessibility text sizes, which always wrap fully.
    let chatRowPreviewLineLimit: Int

    /// Gap between consecutive timeline rows.
    let timelineRowSpacing: CGFloat
    /// Gap between a day heading or unread divider and the row below it.
    let timelineHeadingSpacing: CGFloat
    let bubbleHorizontalInset: CGFloat
    let bubbleVerticalInset: CGFloat
    /// Gap between a bubble and its timestamp row.
    let bubbleMetadataSpacing: CGFloat

    /// The app's original spacing.
    static let standard = AppDensityMetrics(
        chatRowVerticalInset: 6,
        chatRowAvatarSize: 56,
        chatRowAvatarSpacing: 12,
        chatRowLineSpacing: 2,
        chatRowPreviewLineLimit: 2,
        timelineRowSpacing: 4,
        timelineHeadingSpacing: 8,
        bubbleHorizontalInset: ChatBubbleMetrics.horizontalInset,
        bubbleVerticalInset: ChatBubbleMetrics.verticalInset,
        bubbleMetadataSpacing: 3
    )

    static let compact = AppDensityMetrics(
        chatRowVerticalInset: 2,
        chatRowAvatarSize: 44,
        chatRowAvatarSpacing: 10,
        chatRowLineSpacing: 1,
        chatRowPreviewLineLimit: 1,
        timelineRowSpacing: 0,
        timelineHeadingSpacing: 4,
        bubbleHorizontalInset: 10,
        bubbleVerticalInset: 5,
        bubbleMetadataSpacing: 1
    )

    static let comfortable = AppDensityMetrics(
        chatRowVerticalInset: 11,
        chatRowAvatarSize: 64,
        chatRowAvatarSpacing: 14,
        chatRowLineSpacing: 4,
        chatRowPreviewLineLimit: 2,
        timelineRowSpacing: 10,
        timelineHeadingSpacing: 14,
        bubbleHorizontalInset: 14,
        bubbleVerticalInset: 11,
        bubbleMetadataSpacing: 5
    )
}

extension EnvironmentValues {
    @Entry var appDensity: AppDensity = .standard
}

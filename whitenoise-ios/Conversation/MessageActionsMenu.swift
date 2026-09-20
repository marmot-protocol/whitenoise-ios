import SwiftUI
import MarmotKit

nonisolated enum MessageActionsPresentation {
    static let actionHeight: CGFloat = 50
    static let reactionHeight: CGFloat = 56
    static let actionVerticalPadding: CGFloat = 10
    static let surfaceGap: CGFloat = 12
    static let menuWidth: CGFloat = 250
    static let horizontalMargin: CGFloat = 16
    static let verticalMargin: CGFloat = 12
    static let minimumPreviewHeight: CGFloat = 100

    static func actionCount(
        canRetry: Bool,
        canInteract: Bool,
        canForward: Bool,
        canEdit: Bool,
        canViewEditHistory: Bool,
        canDelete: Bool,
        canReport: Bool = false
    ) -> Int {
        var count = 3 // Copy, Info, and Select.
        if canRetry { count += 1 }
        if canInteract { count += 1 }
        if canForward { count += 1 }
        if canEdit { count += 1 }
        if canViewEditHistory { count += 1 }
        if canDelete { count += 1 }
        if canReport { count += 1 }
        return count
    }

    static func actionMenuHeight(actionCount: Int) -> CGFloat {
        CGFloat(actionCount) * actionHeight + actionVerticalPadding * 2
    }

    static func visibleActionHeight(actionCount: Int, containerHeight: CGFloat, showsReactions: Bool) -> CGFloat {
        let reserved = verticalMargin * 2 + minimumPreviewHeight + surfaceGap
            + (showsReactions ? reactionHeight + surfaceGap : 0)
        return min(actionMenuHeight(actionCount: actionCount), max(actionHeight, containerHeight - reserved))
    }

    static func reactionWidth(itemCount: Int, maximumWidth: CGFloat) -> CGFloat {
        min(maximumWidth, CGFloat(itemCount) * 44 + 12)
    }
}

nonisolated struct MessageActionsOverlayLayout: Equatable {
    let groupTop: CGFloat
    let previewHeight: CGFloat
    let previewScale: CGFloat
    let previewCenterY: CGFloat
    let groupCenterY: CGFloat
    let groupHeight: CGFloat

    static func resolve(
        sourceFrame: CGRect,
        containerHeight: CGFloat,
        actionMenuHeight: CGFloat,
        showsReactions: Bool
    ) -> Self {
        let reactionHeight = showsReactions ? MessageActionsPresentation.reactionHeight : 0
        let reactionGap = showsReactions ? MessageActionsPresentation.surfaceGap : 0
        let fixedHeight = reactionHeight
            + reactionGap
            + MessageActionsPresentation.surfaceGap
            + actionMenuHeight
        let availablePreviewHeight = max(
            MessageActionsPresentation.minimumPreviewHeight,
            containerHeight
                - MessageActionsPresentation.verticalMargin * 2
                - fixedHeight
        )
        let previewScale = min(1, availablePreviewHeight / max(sourceFrame.height, 1))
        let previewHeight = sourceFrame.height * previewScale
        let groupHeight = fixedHeight + previewHeight
        let preferredTop = sourceFrame.minY - reactionHeight - reactionGap
        let maximumTop = max(
            MessageActionsPresentation.verticalMargin,
            containerHeight - MessageActionsPresentation.verticalMargin - groupHeight
        )
        let groupTop = min(
            max(preferredTop, MessageActionsPresentation.verticalMargin),
            maximumTop
        )
        let previewTop = groupTop + reactionHeight + reactionGap

        return Self(
            groupTop: groupTop,
            previewHeight: previewHeight,
            previewScale: previewScale,
            previewCenterY: previewTop + previewHeight / 2,
            groupCenterY: groupTop + groupHeight / 2,
            groupHeight: groupHeight
        )
    }
}

/// The two independently styled surfaces around a lifted message preview.
/// The transparent middle keeps the reaction capsule and action panel from
/// acquiring shared popover chrome.
struct MessageActionsMenu: View {
    let canRetry: Bool
    let canInteract: Bool
    let canForward: Bool
    let canEdit: Bool
    let canViewEditHistory: Bool
    let canDelete: Bool
    var canReport: Bool = false
    let quickReactions: [String]
    let selectedReaction: String?
    let previewHeight: CGFloat
    let alignsTrailing: Bool
    let surfaceWidth: CGFloat
    var maximumActionHeight: CGFloat? = nil
    let onRetry: () -> Void
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onCopy: () -> Void
    let onForward: () -> Void
    let onEdit: () -> Void
    let onViewEditHistory: () -> Void
    let onInfo: () -> Void
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onMoreEmoji: () -> Void
    var onReport: () -> Void = {}

    var body: some View {
        VStack(
            alignment: alignsTrailing ? .trailing : .leading,
            spacing: MessageActionsPresentation.surfaceGap
        ) {
            if canInteract { reactionRow }

            Color.clear
                .frame(height: previewHeight)
                .allowsHitTesting(false)

            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    if canRetry {
                        actionRow("Retry send", systemImage: "arrow.clockwise", action: onRetry)
                    }
                    if canInteract {
                        actionRow("Reply", systemImage: "arrowshape.turn.up.left", action: onReply)
                    }
                    if canForward {
                        actionRow("Forward", systemImage: "arrowshape.turn.up.right", action: onForward)
                    }
                    if canEdit {
                        actionRow("Edit", systemImage: "pencil", action: onEdit)
                    }
                    if canViewEditHistory {
                        actionRow("View edit history", systemImage: "clock.arrow.circlepath", action: onViewEditHistory)
                    }
                    actionRow("Copy", systemImage: "doc.on.doc", action: onCopy)
                    actionRow("Select", systemImage: "checkmark.circle", action: onSelect)
                    actionRow("Info", systemImage: "info.circle", action: onInfo)

                    if canReport {
                        actionRow("Report", systemImage: "flag", action: onReport)
                    }
                    if canDelete {
                        actionRow("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    }
                }
                .padding(.vertical, MessageActionsPresentation.actionVerticalPadding)
            }
            .frame(height: maximumActionHeight ?? MessageActionsPresentation.actionMenuHeight(
                actionCount: MessageActionsPresentation.actionCount(canRetry: canRetry, canInteract: canInteract,
                    canForward: canForward, canEdit: canEdit, canViewEditHistory: canViewEditHistory,
                    canDelete: canDelete, canReport: canReport)
            ))
            .clipShape(.rect(cornerRadius: 32))
            .frame(width: MessageActionsPresentation.menuWidth)
            .compatibleInputRoundedChrome(cornerRadius: 32, interactive: false)
            .shadow(color: .black.opacity(0.16), radius: 18, y: 7)
        }
        .frame(width: surfaceWidth)
    }

    private var reactionRow: some View {
        HStack(spacing: 0) {
            ForEach(displayedQuickReactions, id: \.self) { emoji in
                Button {
                    onReact(emoji)
                } label: {
                    Text(emoji)
                        .font(.system(size: 27))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background {
                            if selectedReaction == emoji {
                                Circle().fill(Color(uiColor: .systemFill))
                                    .frame(width: 38, height: 38)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(selectedReaction == emoji ? "Selected" : "")
                .accessibilityAddTraits(selectedReaction == emoji ? .isSelected : [])
            }
            Button {
                onMoreEmoji()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Color(uiColor: .tertiarySystemFill), in: .circle)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More reactions")
        }
        .padding(6)
        .frame(width: reactionWidth)
        .compatibleInputCapsuleChrome(interactive: false)
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
    }

    private var reactionWidth: CGFloat {
        MessageActionsPresentation.reactionWidth(
            itemCount: displayedQuickReactions.count + 1,
            maximumWidth: surfaceWidth
        )
    }

    private var displayedQuickReactions: [String] {
        guard let selectedReaction, !quickReactions.contains(selectedReaction) else {
            return quickReactions
        }
        return quickReactions + [selectedReaction]
    }

    private func actionRow(
        _ title: LocalizedStringKey,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .frame(minHeight: MessageActionsPresentation.actionHeight)
            .contentShape(.rect)
        }
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
    }
}

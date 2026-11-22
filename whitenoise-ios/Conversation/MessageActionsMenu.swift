import SwiftUI
import MarmotKit

extension EnvironmentValues {
    /// Nil for a live row. A lifted row displays the original cards' measured presentation.
    @Entry var liftedDocuments: [String: LiftedDocumentDetails]? = nil
    @Entry var actionRowMeasurementKey: String?
    @Entry var messageActionBodySize: CGSize?
}

nonisolated enum MessageActionsPresentation {
    static func openAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.30, bounce: 0.08)
    }

    static func returnAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.25, bounce: 0)
    }

    static let actionHeight: CGFloat = 50
    static let reactionHeight: CGFloat = 56
    static let actionVerticalPadding: CGFloat = 10
    static let surfaceGap: CGFloat = 12
    static let menuWidth: CGFloat = 250
    static let horizontalMargin: CGFloat = 16
    static let verticalMargin: CGFloat = 12
    static let maximumExcerptBodyHeight: CGFloat = 220
    static let minimumPreviewHeight: CGFloat = 100

    static func actionCount(
        canRetry: Bool,
        canInteract: Bool,
        canCopy: Bool = true,
        canForward: Bool,
        canEdit: Bool,
        canViewEditHistory: Bool,
        canDelete: Bool,
        canReport: Bool = false,
        canBlock: Bool = false,
        canViewVotes: Bool = false,
        canOpenGIF: Bool = false,
        speechActionCount: Int = 0
    ) -> Int {
        var count = 2 + speechActionCount // Info and Select are always present.
        if canCopy { count += 1 }
        if canRetry { count += 1 }
        if canInteract { count += 1 }
        if canForward { count += 1 }
        if canEdit { count += 1 }
        if canViewEditHistory { count += 1 }
        if canDelete { count += 1 }
        if canReport { count += 1 }
        if canBlock { count += 1 }
        if canViewVotes { count += 1 }
        if canOpenGIF { count += 1 }
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

    static func menuCenterX(bubbleEdge: CGFloat, alignsRight: Bool, surfaceWidth: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let half = surfaceWidth / 2
        let minimum = horizontalMargin + half
        let maximum = containerWidth - minimum
        guard maximum >= minimum else { return containerWidth / 2 }
        return min(maximum, max(minimum, bubbleEdge + (alignsRight ? -half : half)))
    }

    static func reactionWidth(itemCount: Int, maximumWidth: CGFloat) -> CGFloat {
        min(maximumWidth, CGFloat(itemCount) * 44 + 12)
    }
}

nonisolated struct MessageActionsOverlayLayout: Equatable {
    let groupTop: CGFloat
    let previewHeight: CGFloat
    let excerptBodyHeight: CGFloat?
    let previewIsTruncated: Bool
    let previewCenterY: CGFloat
    let groupCenterY: CGFloat
    let groupHeight: CGFloat

    static func resolve(
        sourceFrame: CGRect,
        containerHeight: CGFloat,
        actionMenuHeight: CGFloat,
        showsReactions: Bool,
        bodyHeight: CGFloat? = nil
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
        let sourceHeight = max(sourceFrame.height, 1)
        let needsCrop = sourceHeight - availablePreviewHeight > 0.5
        var previewHeight = needsCrop ? availablePreviewHeight : sourceHeight
        var excerptBodyHeight: CGFloat?
        if let bodyHeight, bodyHeight > MessageActionsPresentation.maximumExcerptBodyHeight || needsCrop {
            // Preserve the quote, media and footer when there is room for a readable excerpt.
            let chromeHeight = max(0, sourceHeight - bodyHeight)
            let budget = min(MessageActionsPresentation.maximumExcerptBodyHeight,
                             availablePreviewHeight - chromeHeight)
            if budget >= min(44, bodyHeight), budget < bodyHeight - 0.5 {
                excerptBodyHeight = budget
                previewHeight = chromeHeight + budget
            }
        }
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
            excerptBodyHeight: excerptBodyHeight,
            previewIsTruncated: excerptBodyHeight != nil || needsCrop,
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let presented: Bool
    let bubbleWidth: CGFloat
    let canRetry: Bool
    let canInteract: Bool
    var canCopy = true
    let canForward: Bool
    let canEdit: Bool
    let canViewEditHistory: Bool
    let canDelete: Bool
    var canReport: Bool = false
    var canBlock: Bool = false
    var canViewVotes: Bool = false
    var onOpenGIF: (() -> Void)? = nil
    var speechActions: [MessageSpeechAction] = []
    var transcribeCheckFinished = false
    var onSpeechAction: (MessageSpeechAction) -> Void = { _ in }
    let quickReactions: [String]
    let selectedReaction: String?
    var selectedReactionMessageId: String? = nil
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
    var onBlock: () -> Void = {}
    var onViewVotes: () -> Void = {}

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
                    if let onOpenGIF {
                        actionRow("Open media gallery", systemImage: "photo.on.rectangle", action: onOpenGIF)
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
                    if canViewVotes {
                        actionRow("View votes", systemImage: "person.2", action: onViewVotes)
                    }
                    ForEach(speechActions, id: \.self) { item in
                        actionRow(item.title, systemImage: item.symbol) { onSpeechAction(item) }
                            .disabled(item == .transcribing || (item == .transcribe && !transcribeCheckFinished))
                    }
                    if canCopy { actionRow("Copy", systemImage: "doc.on.doc", action: onCopy) }
                    actionRow("Select", systemImage: "checkmark.circle", action: onSelect)
                    actionRow("Info", systemImage: "info.circle", action: onInfo)

                    if canReport {
                        actionRow("Report", systemImage: "flag", action: onReport)
                    }
                    if canBlock {
                        actionRow("Block", systemImage: "hand.raised", role: .destructive, action: onBlock)
                    }
                    if canDelete {
                        actionRow("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    }
                }
                .padding(.vertical, MessageActionsPresentation.actionVerticalPadding)
            }
            .frame(height: maximumActionHeight ?? MessageActionsPresentation.actionMenuHeight(
                actionCount: MessageActionsPresentation.actionCount(canRetry: canRetry, canInteract: canInteract, canCopy: canCopy,
                    canForward: canForward, canEdit: canEdit, canViewEditHistory: canViewEditHistory,
                    canDelete: canDelete, canReport: canReport, canBlock: canBlock, canViewVotes: canViewVotes,
                    canOpenGIF: onOpenGIF != nil, speechActionCount: speechActions.count)
            ))
            .clipShape(.rect(cornerRadius: 32))
            .frame(width: MessageActionsPresentation.menuWidth)
            .compatibleInputRoundedChrome(cornerRadius: 32, interactive: false)
            .shadow(color: .black.opacity(0.16), radius: 18, y: 7)
            .scaleEffect(reduceMotion || presented ? 1 : 0.2, anchor: alignsTrailing ? .topTrailing : .topLeading)
            .opacity(presented ? 1 : 0)
            .animation(reduceMotion ? .easeOut(duration: 0.15) :
                (presented ? .spring(duration: 0.25, bounce: 0.05) : .easeOut(duration: 0.10)), value: presented)
        }
        .frame(width: surfaceWidth)
    }

    private var reactionRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(displayedQuickReactions.enumerated()), id: \.element) { index, emoji in
                Button {
                    onReact(emoji)
                } label: {
                    CustomEmojiReactionLabel(emoji: emoji,
                        reactionMessageIdHex: emoji == selectedReaction ? selectedReactionMessageId : nil,
                        pointSize: 28, maximumPointSize: MessageActionsPresentation.reactionHeight - 12)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .font(.system(size: 28))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background {
                            if selectedReaction == emoji {
                                Circle().fill(Color(uiColor: .systemFill))
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .modifier(ReactionAppearance(presented: presented, index: index, reduceMotion: reduceMotion))
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
            .modifier(ReactionAppearance(presented: presented, index: displayedQuickReactions.count, reduceMotion: reduceMotion))
            .accessibilityLabel("More reactions")
        }
        .padding(6)
        .frame(width: reactionWidth)
        .compatibleInputCapsuleChrome(interactive: false)
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        .scaleEffect(x: reduceMotion || presented ? 1 : 0.1, y: reduceMotion || presented ? 1 : 0.6,
                     anchor: UnitPoint(x: alignsTrailing ? 1 - reactionAnchor : reactionAnchor, y: 1))
        .opacity(presented ? 1 : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.15) :
            (presented ? .spring(duration: 0.30, bounce: 0.06).delay(0.13) : .easeOut(duration: 0.15)), value: presented)
    }

    private var reactionAnchor: CGFloat {
        min(1, bubbleWidth / max(1, reactionWidth))
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

private struct ReactionAppearance: ViewModifier {
    let presented: Bool
    let index: Int
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion || presented ? 1 : 0.55)
            .opacity(presented ? 1 : 0)
            .animation(reduceMotion ? .easeOut(duration: 0.15) :
                (presented ? .easeOut(duration: 0.16).delay(0.20 + Double(index) * 0.009) : .easeOut(duration: 0.09)),
                value: presented)
    }
}

extension View {
    func messageActionsPreviewTruncation(contentHeight: CGFloat, isTruncated: Bool) -> some View {
        modifier(MessageActionsPreviewTruncation(contentHeight: contentHeight, isTruncated: isTruncated))
    }
}

private struct MessageActionsPreviewTruncation: ViewModifier {
    let contentHeight: CGFloat
    let isTruncated: Bool

    func body(content: Content) -> some View {
        if isTruncated {
            content
                .frame(height: contentHeight, alignment: .top)
                .clipped()
        } else {
            content
        }
    }
}

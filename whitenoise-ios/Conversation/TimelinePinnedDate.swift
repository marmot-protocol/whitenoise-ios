import SwiftUI

struct TimelineDateHeading: Identifiable, Equatable {
    let id: String
    let day: Date
}

struct TimelineInlineDateHeader: View {
    let heading: TimelineDateHeading
    let isFirst: Bool
    let viewport: TimelineDateViewport
    @State private var position = TimelineDatePinning.Position.offscreenBelow

    var body: some View {
        TimelineDateLabel(day: heading.day)
            .foregroundStyle(.secondary)
            .opacity(position == .passed ? 0 : 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, TimelineDatePinning.verticalPadding)
            .accessibilityHidden(position == .passed)
            .allowsHitTesting(false)
            .onGeometryChange(for: TimelineDatePinning.Position.self) { geometry in
                let frame = geometry.frame(in: .scrollView)
                return TimelineDatePinning.position(
                    minY: frame.minY, height: frame.height,
                    viewportHeight: geometry.bounds(of: .scrollView)?.height ?? .infinity,
                    isFirst: isFirst
                )
            } action: { updated in
                position = updated
                viewport.set(updated, for: heading.id)
            }
            .onAppear { viewport.set(position, for: heading.id) }
            .onDisappear { viewport.set(nil, for: heading.id) }
    }
}

/// The day header owning the topmost visible row. Observed only by the pinned
/// date, so a row scrolling past does not rebuild the conversation.
@MainActor
@Observable
final class TimelineDateViewport {
    var headerID: String?
    private(set) var positions: [String: TimelineDatePinning.Position] = [:]

    // Lazy rows can enter and leave independently. Each heading owns its measurement
    // until disappearance, even when a sibling is the last child to update.
    func set(_ position: TimelineDatePinning.Position?, for id: String) {
        if positions[id] != position { positions[id] = position }
    }
}

struct TimelinePinnedDateModifier: ViewModifier {
    let orderedHeaderIDs: [String]
    let headingsByID: [String: TimelineDateHeading]
    let dimsForSearch: Bool
    let viewport: TimelineDateViewport

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    if let presentation = TimelineDatePinning.presentation(
                        orderedHeaderIDs: orderedHeaderIDs, positions: viewport.positions,
                        topRowHeaderID: viewport.headerID,
                        dayForHeader: { headingsByID[$0]?.day }
                    ), let heading = headingsByID[presentation.headerID] {
                        TimelineDateLabel(day: heading.day)
                            .foregroundStyle(.primary)
                            .wnLiftedChrome(in: Capsule())
                            .padding(.vertical, TimelineDatePinning.verticalPadding)
                            .offset(y: presentation.offset)
                            .opacity(presentation.opacity * (dimsForSearch ? 0.28 : 1))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
                .allowsHitTesting(false)
            }
    }
}

private struct TimelineDateLabel: View {
    @Environment(\.locale) private var locale
    let day: Date

    var body: some View {
        Text(ConversationDateHeader.label(timestamp: UInt64(max(0, day.timeIntervalSince1970)), locale: locale))
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .accessibilityAddTraits(.isHeader)
    }
}

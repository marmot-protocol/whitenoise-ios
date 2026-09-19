import SwiftUI

struct TimelineDateHeading: Identifiable, Equatable {
    let id: String
    let day: Date
}

private struct TimelineDatePositionsKey: PreferenceKey {
    static let defaultValue: [String: TimelineDatePinning.Position] = [:]

    static func reduce(
        value: inout [String: TimelineDatePinning.Position],
        nextValue: () -> [String: TimelineDatePinning.Position]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct TimelineInlineDateHeader: View {
    let heading: TimelineDateHeading
    @State private var position = TimelineDatePinning.Position.below

    var body: some View {
        TimelineDateLabel(day: heading.day)
            .foregroundStyle(.secondary)
            .opacity(position == .passed ? 0 : 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .accessibilityHidden(position == .passed)
            .allowsHitTesting(false)
            .onGeometryChange(for: TimelineDatePinning.Position.self) { geometry in
                let frame = geometry.frame(in: .scrollView)
                return TimelineDatePinning.position(minY: frame.minY, height: frame.height)
            } action: { position = $0 }
            .preference(key: TimelineDatePositionsKey.self, value: [heading.id: position])
    }
}

struct TimelinePinnedDateModifier: ViewModifier {
    let headings: [TimelineDateHeading]
    @State private var positions: [String: TimelineDatePinning.Position] = [:]

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(TimelineDatePositionsKey.self) { positions = $0 }
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    if let presentation = TimelineDatePinning.presentation(
                        orderedHeaderIDs: headings.map(\.id), positions: positions
                    ), let heading = headings.first(where: { $0.id == presentation.headerID }) {
                        TimelineDateLabel(day: heading.day)
                            .foregroundStyle(.primary)
                            .wnLiftedChrome(in: Capsule())
                            .padding(.vertical, 18)
                            .offset(y: presentation.offset)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
                .allowsHitTesting(false)
            }
    }
}

private struct TimelineDateLabel: View {
    let day: Date

    var body: some View {
        Text(ConversationDateHeader.label(timestamp: UInt64(max(0, day.timeIntervalSince1970))))
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .accessibilityAddTraits(.isHeader)
    }
}

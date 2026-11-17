import SwiftUI
import UIKit

/// Equal-width primary action for the details header rows (Add, Mute,
/// Search…). Icon over a short label, minimum 44-point target.
enum DetailsActionButtonAppearance {
    case bordered
    case circular
}

struct DetailsActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isDisabled = false
    var isLoading = false
    var appearance: DetailsActionButtonAppearance = .bordered
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        switch appearance {
        case .bordered:
            Button(action: action) {
                label
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.rect)
            }
            .wnSecondaryButtonStyle()
            .disabled(isDisabled || isLoading)
        case .circular:
            DetailsQuickAction(title: title, size: .compact) {
                Button(action: action) { icon }
                    .disabled(isDisabled || isLoading)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var label: some View {
        VStack(spacing: 4) {
            icon
            Text(title)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    @ViewBuilder
    private var icon: some View {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
            }
        }
        .accessibilityHidden(true)
    }
}

struct DetailsQuickAction<Control: View>: View {
    enum Size {
        case compact
        case regular

        var diameter: CGFloat { self == .compact ? 44 : 64 }
        var font: Font { self == .compact ? .body.weight(.semibold) : .title3 }
    }

    let title: LocalizedStringKey
    var size = Size.regular
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(spacing: 6) {
            control()
                .buttonStyle(DetailsQuickActionStyle(diameter: size.diameter, font: size.font))
                .accessibilityLabel(title)
            Text(title)
                .font(.footnote)
                .lineLimit(1)
                .minimumScaleFactor(DetailsQuickActionsGridLayout.labelMinimumScaleFactor)
                .accessibilityHidden(true)
        }
    }
}

private struct DetailsQuickActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let diameter: CGFloat
    let font: Font

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(.primary)
            .frame(width: diameter, height: diameter)
            .compatibleInputCircleChrome()
            .contentShape(.circle)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

/// The details header's quick actions at accessibility sizes: a grid of the
/// most columns whose labels fit, rather than one row of truncated labels.
struct DetailsQuickActionsGridLayout: Layout {
    var spacing: CGFloat = 12
    var maximumColumns = 2

    /// `DetailsQuickAction` labels may shrink this far before they truncate.
    nonisolated static let labelMinimumScaleFactor: CGFloat = 0.8

    nonisolated static func columnCount(
        itemWidths: [CGFloat],
        availableWidth: CGFloat,
        spacing: CGFloat,
        maximumColumns: Int,
        minimumScaleFactor: CGFloat = labelMinimumScaleFactor
    ) -> Int {
        guard let widest = itemWidths.max().map({ $0 * minimumScaleFactor }) else { return 1 }
        var columns = min(maximumColumns, itemWidths.count)
        while columns > 1 {
            let cellWidth = (availableWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            if widest <= cellWidth { return columns }
            columns -= 1
        }
        return 1
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (columns: Int, cellWidth: CGFloat) {
        let columns = Self.columnCount(
            itemWidths: subviews.map { $0.sizeThatFits(.unspecified).width },
            availableWidth: width,
            spacing: spacing,
            maximumColumns: maximumColumns
        )
        let cellWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        return (columns, cellWidth)
    }

    private func rowHeights(columns: Int, cellWidth: CGFloat, subviews: Subviews) -> [CGFloat] {
        let cell = ProposedViewSize(width: cellWidth, height: nil)
        return stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(cell).height }
                .max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let (columns, cellWidth) = arrangement(width: width, subviews: subviews)
        let heights = rowHeights(columns: columns, cellWidth: cellWidth, subviews: subviews)
        return CGSize(
            width: width,
            height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1))
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let (columns, cellWidth) = arrangement(width: bounds.width, subviews: subviews)
        let heights = rowHeights(columns: columns, cellWidth: cellWidth, subviews: subviews)
        let cell = ProposedViewSize(width: cellWidth, height: nil)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            let start = row * columns
            let rowItems = subviews[start..<min(start + columns, subviews.count)]
            // Center a short last row instead of leaving it flush left.
            let rowWidth = CGFloat(rowItems.count) * cellWidth + spacing * CGFloat(rowItems.count - 1)
            var x = bounds.minX + (bounds.width - rowWidth) / 2
            for item in rowItems {
                item.place(
                    at: CGPoint(x: x + cellWidth / 2, y: y + height / 2),
                    anchor: .center,
                    proposal: cell
                )
                x += cellWidth + spacing
            }
            y += height + spacing
        }
    }
}

extension DynamicTypeSize {
    /// The details header's quick actions: one row, or a grid at accessibility sizes.
    var detailsQuickActionsLayout: AnyLayout {
        isAccessibilitySize
            ? AnyLayout(DetailsQuickActionsGridLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
    }
}

import SwiftUI
import MarmotKit

/// The collapsed card for an event this app can't render. Tapping it opens the event data.
struct UnsupportedEventCard: View {
    @Environment(\.appDensity) private var density

    let presentation: UnsupportedEventPresentation
    let isFromMe: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "curlybraces")
                        .accessibilityHidden(true)
                    TimelineSearchText(L10n.string("Unsupported event"))
                        .fontWeight(.semibold)
                    TimelineSearchText(UnsupportedEventPresentation.kindLabel(presentation.kind))
                        .monospacedDigit()
                }
                .font(.footnote)
                .foregroundStyle(secondary)

                if let title = presentation.title {
                    TimelineSearchText(title, keepsMatchVisible: true)
                        .font(.headline)
                        .foregroundStyle(MessageBubblePalette.foreground(isFromMe: isFromMe))
                }
                if let summary = presentation.summary {
                    TimelineSearchText(summary, keepsMatchVisible: true)
                        .font(.subheadline)
                        .foregroundStyle(secondary)
                        .lineLimit(3)
                }

                HStack(spacing: 4) {
                    Text(L10n.string("View Event Data"))
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(MessageBubblePalette.foreground(isFromMe: isFromMe))
                .padding(.top, 2)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, density.metrics.bubbleHorizontalInset)
            .padding(.vertical, density.metrics.bubbleVerticalInset)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var secondary: Color {
        MessageBubblePalette.secondaryForeground(isFromMe: isFromMe)
    }
}

/// The raw event behind an unsupported-event card, as formatted JSON.
struct UnsupportedEventSheet: View {
    @Environment(\.dismiss) private var dismiss

    let record: AppMessageRecordFfi
    let senderName: String?

    var body: some View {
        let presentation = UnsupportedEventPresentation(record: record)
        let json = UnsupportedEventPresentation.eventJSON(for: record)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(UnsupportedEventPresentation.kindLabel(presentation.kind))
                            .font(.footnote.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if let title = presentation.title {
                            Text(verbatim: title)
                                .font(.title3.weight(.semibold))
                        }
                        if let summary = presentation.summary {
                            Text(verbatim: summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(byline)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    EventJSONText(text: json)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            Color(uiColor: .secondarySystemBackground),
                            in: .rect(cornerRadius: 12, style: .continuous)
                        )

                }
                .padding()
            }
            .navigationTitle(L10n.string("Event Data"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // In the toolbar so it stays in reach however long the JSON is.
                ToolbarItem(placement: .topBarLeading) {
                    WNCopyButton(value: json, accessibilityTitle: L10n.string("Copy JSON")) { copied in
                        Label {
                            Text(copied ? L10n.string("Copied") : L10n.string("Copy JSON"))
                        } icon: {
                            WNCopyIcon(copied: copied)
                        }
                        .labelStyle(.titleAndIcon)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var byline: String {
        let date = Date(timeIntervalSince1970: TimeInterval(record.recordedAt))
            .formatted(date: .abbreviated, time: .shortened)
        guard let senderName, !senderName.isEmpty else { return date }
        return L10n.formatted("%@ · %@", senderName, date)
    }
}

/// Selectable monospaced JSON that wraps anywhere. SwiftUI `Text` hyphenates long
/// tokens when it wraps, which would put a hyphen inside an id.
private struct EventJSONText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byCharWrapping
        view.adjustsFontForContentSizeCategory = true
        view.dataDetectorTypes = []
        // 13 pt is footnote at the default text size; the metrics scale it with Dynamic Type.
        view.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.textColor = .label
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard view.text != text else { return }
        view.text = text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: ceil(height))
    }
}

import MarmotKit
import SwiftUI

/// MDK's exact relay-list diff, grouped by what saving would do to each entry.
struct AccountSetupRelayRepairSections: View {
    let repair: AccountSetupRelayRepairPresentation
    var showsRoles = true

    var body: some View {
        if repair.isManualReview {
            if !repair.kept.isEmpty { section("Current relays", rows: repair.kept) }
        } else {
            if !repair.added.isEmpty { section("Will be added", rows: repair.added) }
            if !repair.removed.isEmpty { section("Will be removed", rows: repair.removed) }
            if !repair.kept.isEmpty { section("Unchanged", rows: repair.kept) }
        }
    }

    private func section(_ title: LocalizedStringKey, rows: [AccountSetupRelayRepairPresentation.Row]) -> some View {
        Section {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                AccountSetupRelayRepairRow(row: row, showsRoles: showsRoles, changeLabel: title)
                    .wnGroupedCardRow(.at(index, of: rows.count))
            }
        } header: {
            Text(title)
        }
    }
}

private struct AccountSetupRelayRepairRow: View {
    let row: AccountSetupRelayRepairPresentation.Row
    let showsRoles: Bool
    let changeLabel: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(symbolColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if row.use == .other {
                        Text("Other entry")
                    } else {
                        Text(verbatim: row.host ?? L10n.string("Relay"))
                    }
                }
                .font(.body)
                .strikethrough(row.change == .removed)
                if let text = row.text {
                    Text(verbatim: text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if row.isInvalidPublishedAddress {
                    Text("Invalid relay address").font(.subheadline).foregroundStyle(.red)
                }
                if showsRoles, let role = roleLabel {
                    Text(role).font(.subheadline).foregroundStyle(.secondary)
                }
                if let capability = capabilityLabel {
                    Text(capability).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(changeLabel))
    }

    private var symbol: String {
        switch row.change {
        case .added: "plus.circle.fill"
        case .removed: "minus.circle.fill"
        case .kept: "equal.circle"
        }
    }

    private var symbolColor: Color {
        switch row.change {
        case .added: .green
        case .removed: .red
        case .kept: .secondary
        }
    }

    private var roleLabel: LocalizedStringKey? {
        switch row.use {
        case .readAndWrite: "Read and write"
        case .read: "Read only"
        case .write: "Write only"
        case .inbox, .other: nil
        }
    }

    private var capabilityLabel: LocalizedStringKey? {
        switch row.restores {
        case .read: "Lets your profile find public information."
        case .write: "Lets your profile publish information."
        case .readAndWrite: "Lets your profile find and publish public information."
        case .inbox: "Lets you receive chat invitations."
        case .none: nil
        }
    }
}

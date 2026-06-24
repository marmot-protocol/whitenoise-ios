import SwiftUI

/// Inline system-style row in the conversation timeline.
struct SystemEventRow: View {
    let event: SystemEvent

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var text: String {
        switch event {
        case .groupCreated: L10n.string("Chat created")
        case .groupRenamed(let new): L10n.formatted("Renamed to %@", new)
        case .groupArchived: L10n.string("Chat archived")
        case .groupUnarchived: L10n.string("Chat unarchived")
        case .rosterChanged: L10n.string("Membership changed")
        }
    }

    private var icon: String {
        switch event {
        case .groupCreated: "sparkles"
        case .groupRenamed: "pencil"
        case .groupArchived: "archivebox"
        case .groupUnarchived: "tray.and.arrow.up"
        case .rosterChanged: "person.2.fill"
        }
    }
}

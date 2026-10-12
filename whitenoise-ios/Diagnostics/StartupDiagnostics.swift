import SwiftUI
import MarmotKit

/// Device-wide preference; read by `MarmotClient` before any account query.
nonisolated enum StartupDiagnosticsPreference {
    static let key = "marmot.startupDiagnosticsEnabled"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

/// Presentation for MDK's native startup snapshot. The snapshot holds only
/// fixed phases, durations and migration numbers: no paths, identifiers or
/// error text, so it is safe to show and export as-is.
nonisolated enum StartupDiagnosticsPresentation {
    struct Row: Equatable, Identifiable {
        let id: String
        let stage: String
        let detail: String
    }

    static func rows(_ observations: [NativeStartupObservationFfi]) -> [Row] {
        observations.enumerated().map { index, observation in
            Row(id: "\(observation.token)-\(index)", stage: stageName(observation.stage),
                detail: detail(observation))
        }
    }

    static func detail(_ observation: NativeStartupObservationFfi) -> String {
        var parts = [
            "\(observation.stageElapsedMs) ms",
            "total \(observation.elapsedMs) ms",
            outcomeName(observation.outcome)
        ]
        if let version = observation.migrationVersion {
            parts.append("migration \(version)")
        }
        if observation.migrationsCompleted > 0 {
            parts.append("\(observation.migrationsCompleted) migrations done")
        }
        return parts.joined(separator: " · ")
    }

    static func exportText(_ snapshot: NativeStartupSnapshotFfi) -> String {
        var lines = [
            "White Noise startup diagnostics",
            "enabled: \(snapshot.enabled)",
            "dropped events: \(snapshot.droppedEvents)",
            "dropped scopes: \(snapshot.droppedScopes)",
            "",
            "active:"
        ]
        lines += snapshot.active.map { "  #\($0.token) \(stageName($0.stage)) \(detail($0))" }
        lines += ["", "events:"]
        lines += snapshot.events.map { "  #\($0.token) \(stageName($0.stage)) \(detail($0))" }
        return lines.joined(separator: "\n")
    }

    static func outcomeName(_ outcome: NativeStartupOutcomeFfi) -> String {
        switch outcome {
        case .active: "active"
        case .success: "success"
        case .failure: "failure"
        case .abandoned: "abandoned"
        }
    }

    /// Enum case names, which match MDK's documented phase names.
    static func stageName(_ stage: NativeStartupStageFfi) -> String {
        String(describing: stage)
    }
}

/// Developer Tools screen for slow-open investigations.
struct StartupDiagnosticsView: View {
    @Environment(AppState.self) private var appState
    @State private var snapshot: NativeStartupSnapshotFfi?
    @State private var loadError: String?

    var body: some View {
        Form {
            Section {
                WNToggle("Capture Startup Diagnostics", isOn: Binding(
                    get: { appState.startupDiagnosticsEnabled },
                    set: { appState.startupDiagnosticsEnabled = $0; refresh() }
                ))
            } footer: {
                Text("Records how long each step of opening accounts takes, starting at the next launch. It contains no account details and is never uploaded. Turning it off clears what was recorded.")
            }

            if let loadError {
                Section { Text(loadError).foregroundStyle(.secondary) }
            }

            if let snapshot {
                Section {
                    LabeledContent("Dropped events", value: snapshot.droppedEvents, format: .number)
                    LabeledContent("Dropped scopes", value: snapshot.droppedScopes, format: .number)
                    ShareLink(item: StartupDiagnosticsPresentation.exportText(snapshot)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                if !snapshot.active.isEmpty {
                    Section("In Progress") { rows(snapshot.active) }
                }
                Section("Steps") {
                    if snapshot.events.isEmpty {
                        Text("Nothing recorded yet.").foregroundStyle(.secondary)
                    } else {
                        rows(snapshot.events)
                    }
                }
            }
        }
        .localizedNavigationTitle("Startup Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private func rows(_ observations: [NativeStartupObservationFfi]) -> some View {
        ForEach(StartupDiagnosticsPresentation.rows(observations)) { row in
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.stage).font(.subheadline.monospaced())
                Text(verbatim: row.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// A synchronous clone of independent memory; it never touches storage.
    private func refresh() {
        guard let client = appState.client else {
            snapshot = nil
            loadError = L10n.string("The runtime isn't running.")
            return
        }
        do {
            snapshot = try client.marmot.startupDiagnosticsSnapshot()
            loadError = nil
        } catch {
            snapshot = nil
            loadError = UserFacingError.message(for: error)
        }
    }
}

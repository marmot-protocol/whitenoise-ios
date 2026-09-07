import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticLogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

nonisolated enum DiagnosticLogExport {
    static let maximumBytes = 16 * 1024 * 1024

    /// Export an activity summary, excluding identities, source labels and event payloads.
    static func summaryLine(_ data: Data) -> String? {
        guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = row["kind"] as? [String: Any],
              let type = kind["type"] as? String, knownEvents.contains(type),
              let time = row["wall_time_ms"] as? UInt64 else { return nil }
        let date = Date(timeIntervalSince1970: Double(time) / 1_000)
        return "\(date.formatted(.iso8601)) | \(type)"
    }

    static func report(paths: [String]) throws -> String {
        var lines = ["White Noise Diagnostic Logs", "Activity summary. Identities, filenames, source labels and event payloads are excluded.", ""]
        var remaining = maximumBytes
        var omitted = false
        for path in paths {
            guard remaining > 0 else { omitted = true; break }
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            let data = try handle.read(upToCount: remaining + 1) ?? Data()
            let accepted = data.prefix(remaining)
            remaining -= accepted.count
            if data.count > accepted.count { omitted = true }
            var rows = accepted.split(separator: 0x0A, omittingEmptySubsequences: true)
            // A recorder may still be appending the final row.
            if accepted.last != 0x0A { rows = rows.dropLast() }
            for row in rows {
                if let line = summaryLine(Data(row)) { lines.append(line) } else { omitted = true }
            }
        }
        if omitted { lines.append("Some records were omitted because they were incomplete, unsupported, or exceeded the export limit.") }
        return lines.joined(separator: "\n") + "\n"
    }

    private static let knownEvents: Set<String> = [
        "recorder_started", "engine_context", "group_context",
        "recorder_health", "human_action", "transport_received",
        "ingest_entry", "ingest_outcome", "ingest_error",
        "send_entry", "source_context", "recipient_expectation",
        "send_outcome", "send_error", "create_group_entry",
        "create_group_outcome", "create_group_error", "publish_attempt",
        "publish_outcome", "publish_failure", "epoch_confirmed",
        "epoch_rolled_back", "epoch_state_changed", "group_state_changed",
        "pending_commit_recovered_on_open", "group_hydration_quarantined", "group_hydration_recovered",
        "snapshot_created", "fork_resolution", "convergence_run_state",
        "convergence_decision", "peeler_outcome", "auto_commit_decision",
        "message_state_changed", "rejection", "subscription_rebuild",
        "sync_drain", "epoch_stall_backfill_armed", "epoch_stall_backfill_started",
        "epoch_stall_backfill_completed", "epoch_stall_backfill_failed", "epoch_stall_backfill_deferred",
        "epoch_stall_backfill_escalated", "convergence_pass_discarded"
    ]
}

import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

struct DiagnosticLogExportTests {
    @Test func latestUsesModificationTimeAcrossAccountsAndIgnoresEmptyFiles() throws {
        let older = file("audit-z.jsonl", modified: 10)
        let latest = file("audit-a.jsonl", modified: 20, account: "second")
        let empty = file("audit-empty.jsonl", modified: 30, size: 0)
        let unknown = file("audit-unknown.jsonl", modified: nil)
        let files = [older, empty, unknown, latest]
        #expect(try DiagnosticLogExport.fileForExport(in: files) == latest)
        #expect(try DiagnosticLogExport.fileForExport(in: files.reversed()) == latest)
    }

    @Test func selectionExportsTheRequestedSegmentAndNeverFallsBackToAnotherFile() throws {
        let segment = file("audit-engine-v3-seg000001.jsonl", modified: 10)
        let active = file("audit-engine-v3.jsonl", modified: 20)
        #expect(try DiagnosticLogExport.fileForExport(in: [segment, active], path: segment.path) == segment)
        #expect(throws: DiagnosticLogExport.ExportError.self) {
            try DiagnosticLogExport.fileForExport(in: [active], path: segment.path)
        }
        #expect(throws: DiagnosticLogExport.ExportError.self) {
            try DiagnosticLogExport.fileForExport(in: [])
        }
    }

    @Test func equalTimestampsSelectDeterministicallyIncludingActiveAndSealedFiles() throws {
        let segment = file("audit-engine-v3-seg000001.jsonl", modified: 20)
        let active = file("audit-engine-v3.jsonl", modified: 20)
        #expect(try DiagnosticLogExport.fileForExport(in: [segment, active]) == active)
        #expect(try DiagnosticLogExport.fileForExport(in: [active, segment]) == active)
    }

    @Test func snapshotPreservesEveryByteIncludingUnknownEventsAndPayloadFields() throws {
        let data = Data("""
        {"wall_time_ms":1700000000000,"kind":{"type":"epoch_confirmed","epoch":17},"account_ref":"fixture-account","context":{"source":{"device_name":"fixture device"}}}
        {"kind":{"type":"future_event","details":{"nested":[1,2,3],"text":"café 🌲"}}}

        """.utf8)
        try withLog(data) { log in
            let snapshot = try DiagnosticLogExport.snapshot(file: log)
            #expect(snapshot.fileName == log.fileName)
            #expect(snapshot.data == data)
        }
    }

    @Test func snapshotReadsWholeFileBeyondOldSummaryLimitAndStaleListedSize() throws {
        let row = Data("{\"kind\":{\"type\":\"fixture\"},\"payload\":\"unchanged\"}\n".utf8)
        var data = Data()
        while data.count <= 16 * 1024 * 1024 { data.append(row) }
        try withLog(data) { log in
            var stale = log
            stale.sizeBytes = 1
            let snapshot = try DiagnosticLogExport.snapshot(file: stale)
            #expect(snapshot.data == data)
        }
    }

    @Test func incompleteRecordFailsInsteadOfSilentlyDroppingData() throws {
        try withLog(Data("{\"kind\":{\"type\":\"fixture\"}}\n{\"partial\":".utf8)) { log in
            #expect(throws: DiagnosticLogExport.ExportError.self) {
                try DiagnosticLogExport.snapshot(file: log)
            }
        }
    }

    private func file(
        _ name: String, modified: UInt64?, size: UInt64 = 1, account: String = "first"
    ) -> AuditLogFileFfi {
        AuditLogFileFfi(accountRef: account, path: "/\(account)/\(name)", fileName: name,
                        sizeBytes: size, modifiedAtMs: modified)
    }

    private func withLog(_ data: Data, body: (AuditLogFileFfi) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("audit-fixture-v3.jsonl")
        try data.write(to: url)
        try body(AuditLogFileFfi(accountRef: "fixture", path: url.path, fileName: url.lastPathComponent,
                                 sizeBytes: UInt64(data.count), modifiedAtMs: 1))
    }
}

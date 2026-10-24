import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

@MainActor
struct AuditV5AdoptionTests {
    @Test func auditOtlpConfigIsDisabledWithoutAToken() {
        let config = Self.telemetry(auditToken: nil).auditOtlpConfig()
        #expect(config.enabled == false)
        #expect(config.destination == nil)
        #expect(config.endpoint == nil)
        #expect(config.authorizationBearerToken == nil)
    }

    @Test func auditOtlpConfigTargetsTheV5ReceiverWithTheSharedAuditToken() {
        let config = Self.telemetry(auditToken: "audit-token").auditOtlpConfig()
        #expect(config.enabled)
        #expect(config.destination == TelemetryBuildConfig.auditOtlpDestination)
        #expect(config.endpoint == "https://otlp.whitenoise.chat/v1/logs")
        #expect(config.authorizationBearerToken == "audit-token")
        #expect(config.allowLoopbackDev == false)
    }

    // A destination the native runtime refused would silently disable audit export.
    @Test(.tags(.runtime), .marmotRuntimeConcurrencyLimit)
    func nativeRuntimeAcceptsTheAppAuditDestination() async throws {
        try await withTestClient { client in
            let applied = try client.marmot.setAuditOtlpConfigV5(
                config: Self.telemetry(auditToken: "audit-token").auditOtlpConfig()
            )
            #expect(applied.enabled)
            #expect(applied.destination == TelemetryBuildConfig.auditOtlpDestination)
            #expect(applied.endpoint == "https://otlp.whitenoise.chat/v1/logs")
        }
    }

    @Test(.tags(.runtime), .marmotRuntimeConcurrencyLimit)
    func runtimeStartsWhenTheAuditDestinationIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Self.telemetry(auditToken: "audit-token")
        config.auditOtlpEndpoint = "http://collector.invalid.test/not-logs"
        let client = try MarmotClient(rootPath: root.path, relayUrls: ["wss://relay.invalid.test"],
                                      cursorPersistence: .advance, telemetryConfig: config)
        try await closing(client) {}
    }

    @Test func exportSelectsTheNewestNonEmptyAuditFileAndPreservesItsOriginalBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = String(repeating: "a", count: 32)
        let records = [
            #"{"schema_version":"marmot-forensics-audit/v5","wall_time_ms":1700000000000,"kind":{"type":"recorder_started"}}"#,
            #"{"schema_version":"marmot-forensics-audit/v5","wall_time_ms":1700000000001,"kind":{"type":"identity_created","account_ref":"fixture"}}"#,
            #"{"schema_version":"marmot-forensics-audit/v5","wall_time_ms":1700000000002,"kind":{"type":"recorder_stopped"},"context":{"text":"café 🌲"}}"#,
        ]
        let data = Data((records.joined(separator: "\n") + "\n").utf8)
        func write(_ name: String, _ bytes: Data, modifiedAtMs: UInt64) throws -> AuditLogFileFfi {
            let url = root.appendingPathComponent(name)
            try bytes.write(to: url)
            return AuditLogFileFfi(accountRef: "fixture", path: url.path, fileName: name,
                                   sizeBytes: UInt64(bytes.count), modifiedAtMs: modifiedAtMs)
        }
        let legacy = try write("audit-\(engine)-v4.jsonl", Data("{\"schema_version\":\"marmot-forensics-audit/v4\"}\n".utf8), modifiedAtMs: 1)
        let current = try write("audit-\(engine)-v5.jsonl", data, modifiedAtMs: 2)
        let emptyNewest = try write("audit-\(engine)-v5-seg000002.jsonl", Data(), modifiedAtMs: 3)

        // Selection is by modification time, not by version: a later v4 file wins.
        let laterLegacy = try write("audit-\(engine)-later-v4.jsonl", Data("{\"schema_version\":\"marmot-forensics-audit/v4\"}\n".utf8), modifiedAtMs: 4)
        #expect(try DiagnosticLogExport.fileForExport(in: [current, laterLegacy, emptyNewest]) == laterLegacy)

        let file = try DiagnosticLogExport.fileForExport(in: [legacy, current, emptyNewest])
        let snapshot = try await Task.detached { try DiagnosticLogExport.snapshot(file: file) }.value
        #expect(file.fileName.contains("-v5"))
        #expect(snapshot.fileName == file.fileName)
        #expect(snapshot.data == (try Data(contentsOf: URL(fileURLWithPath: file.path))))
        let lines = snapshot.data.split(separator: 0x0A)
        #expect(lines.count == records.count)
        for line in lines {
            let event = try #require(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
            #expect(event["schema_version"] as? String == "marmot-forensics-audit/v5")
        }
    }

    private static func telemetry(auditToken: String?) -> TelemetryBuildConfig {
        TelemetryBuildConfig(
            otlpEndpoint: "https://collector.invalid.test/v1/metrics", bearerToken: nil, auditLogBearerToken: auditToken,
            deploymentEnvironment: "test", serviceVersion: "test-v5", osVersion: "18.0",
            deviceModelIdentifier: "iPhone17,3"
        )
    }
}

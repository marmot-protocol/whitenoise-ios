import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

@MainActor
struct AuditV5AdoptionTests {
    @Test func nativeStartupDeletesLegacyAuditFilesWithRecordingDisabled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = String(repeating: "a", count: 32)
        var deleted: [URL] = []
        var preserved: [URL] = []
        for container in ["accounts", ".wipe-tombstones"] {
            let account = root.appendingPathComponent(container).appendingPathComponent("fixture")
            try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
            for suffix in ["", "-v1", "-v2", "-v3", "-v3-seg000001"] {
                let file = account.appendingPathComponent("audit-\(engine)\(suffix).jsonl")
                try Data("old incomplete record".utf8).write(to: file)
                deleted.append(file)
            }
            for name in ["audit-\(engine)-v4.jsonl", "audit-\(engine)-v5.jsonl", "audit-key-reveal.jsonl", "unrelated.txt"] {
                let file = account.appendingPathComponent(name)
                try Data("preserved".utf8).write(to: file)
                preserved.append(file)
            }
        }
        let client = try MarmotClient(rootPath: root.path, relayUrls: ["wss://relay.invalid.test"],
                                      cursorPersistence: .advance)
        do {
            for file in deleted { #expect(!FileManager.default.fileExists(atPath: file.path)) }
            for file in preserved { #expect(try Data(contentsOf: file) == Data("preserved".utf8)) }
            #expect(try client.marmot.auditLogSettings().enabled == false)
            try await client.marmot.shutdownAndClose()
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }

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

    @Test func auditOtlpConfigRoundTripsThroughNativeV5BindingsWithTheTokenRedacted() async throws {
        let client = try MarmotClient.testClient()
        defer { try? FileManager.default.removeItem(atPath: client.rootPath) }
        do {
            let enabled = try client.marmot.setAuditOtlpConfigV5(
                config: Self.telemetry(auditToken: "audit-token").auditOtlpConfig()
            )
            #expect(enabled.enabled)
            #expect(enabled.destination == TelemetryBuildConfig.auditOtlpDestination)
            #expect(enabled.endpoint == "https://otlp.whitenoise.chat/v1/logs")
            #expect(enabled.authorizationBearerToken == nil)
            let disabled = try client.marmot.setAuditOtlpConfigV5(
                config: Self.telemetry(auditToken: nil).auditOtlpConfig()
            )
            #expect(disabled.enabled == false)
            try await client.marmot.shutdownAndClose()
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }

    @Test func runtimeStartsWhenTheAuditDestinationIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Self.telemetry(auditToken: "audit-token")
        config.auditOtlpEndpoint = "http://collector.invalid.test/not-logs"
        let client = try MarmotClient(rootPath: root.path, relayUrls: ["wss://relay.invalid.test"],
                                      cursorPersistence: .advance, telemetryConfig: config)
        try await client.marmot.shutdownAndClose()
    }

    @Test func nativeRecorderProducesV5AndExportsItsOriginalBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try MarmotClient(rootPath: root.path, relayUrls: ["wss://relay.invalid.test"],
                                      cursorPersistence: .advance, telemetryConfig: Self.telemetry(auditToken: nil))
        do {
            try await client.startRuntime()
            // Local identity preparation opens the recorder before returning;
            // enabling afterward depends on the background account worker.
            _ = try await client.marmot.setAuditLogSettings(settings: AuditLogSettingsFfi(enabled: true))
            _ = try await client.marmot.createIdentityWithProfile(
                defaultRelays: ["wss://relay.invalid.test"], bootstrapRelays: ["wss://relay.invalid.test"]
            )
            _ = try await client.marmot.setAuditLogSettings(settings: AuditLogSettingsFfi(enabled: false))
            let files = try await client.auditLogFiles()
            let file = try DiagnosticLogExport.fileForExport(in: files)
            let snapshot = try await Task.detached { try DiagnosticLogExport.snapshot(file: file) }.value
            #expect(file.fileName.contains("-v5"))
            #expect(snapshot.fileName == file.fileName)
            #expect(snapshot.data == (try Data(contentsOf: URL(fileURLWithPath: file.path))))
            let lines = snapshot.data.split(separator: 0x0A)
            #expect(!lines.isEmpty)
            for line in lines {
                let event = try #require(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
                #expect(event["schema_version"] as? String == "marmot-forensics-audit/v5")
            }
            try await client.marmot.shutdownAndClose()
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
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

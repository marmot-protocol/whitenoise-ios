import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

@MainActor
struct AuditV4AdoptionTests {
    private static let auditSettleTimeout = Duration.seconds(10)
    private static let minimumAuditSchedulingOpportunities = 400

    private func waitForRecordedAuditBytes(
        _ client: MarmotClient,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: Self.auditSettleTimeout)
        var schedulingOpportunities = 0
        while true {
            if try await client.auditLogFiles().contains(where: { $0.sizeBytes > 0 }) { return }
            guard schedulingOpportunities < Self.minimumAuditSchedulingOpportunities
                    || ContinuousClock.now < deadline
            else { break }
            schedulingOpportunities += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record(
            """
            native recorder wrote no audit bytes within \(Self.auditSettleTimeout) or \
            \(schedulingOpportunities) main-actor scheduling opportunities
            """,
            sourceLocation: sourceLocation
        )
    }

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

    @Test func trackerMetadataRoundTripsThroughNativeV4BindingsWithOptionalHardware() async throws {
        let client = try MarmotClient.testClient()
        defer { try? FileManager.default.removeItem(atPath: client.rootPath) }
        do {
            for hardware: String? in ["iPhone17,3", nil] {
                let config = TelemetryBuildConfig(
                    otlpEndpoint: "https://collector.invalid.test/v1/metrics", bearerToken: nil, auditLogBearerToken: nil,
                    deploymentEnvironment: "test", serviceVersion: "test-v4", osVersion: "18.0",
                    deviceModelIdentifier: hardware
                )
                let tracker = try client.marmot.setAuditLogTrackerConfig(config: config.auditTrackerConfig())
                let source = tracker.source
                #expect(source.hardwareModel == hardware)
                #expect(source.platform == "ios")
                #expect(source.appVersion == "test-v4")
            }
            try await client.marmot.shutdownAndClose()
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }

    @Test func nativeRecorderProducesV4AndExportsItsOriginalBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = TelemetryBuildConfig(
            otlpEndpoint: "https://collector.invalid.test/v1/metrics", bearerToken: nil, auditLogBearerToken: nil,
            deploymentEnvironment: "test", serviceVersion: "test-v4", osVersion: "18.0",
            deviceModelIdentifier: "iPhone17,3"
        )
        let client = try MarmotClient(rootPath: root.path, relayUrls: ["wss://relay.invalid.test"],
                                      cursorPersistence: .advance, telemetryConfig: config)
        do {
            try await client.startRuntime()
            _ = try await client.marmot.createIdentityWithProfile(
                defaultRelays: ["wss://relay.invalid.test"], bootstrapRelays: ["wss://relay.invalid.test"]
            )
            _ = try await client.marmot.setAuditLogSettings(settings: AuditLogSettingsFfi(enabled: true))
            try await waitForRecordedAuditBytes(client)
            _ = try await client.marmot.setAuditLogSettings(settings: AuditLogSettingsFfi(enabled: false))
            let files = try await client.auditLogFiles()
            let file = try DiagnosticLogExport.fileForExport(in: files)
            let snapshot = try await Task.detached { try DiagnosticLogExport.snapshot(file: file) }.value
            #expect(file.fileName.hasSuffix("-v4.jsonl"))
            #expect(snapshot.fileName == file.fileName)
            #expect(snapshot.data == (try Data(contentsOf: URL(fileURLWithPath: file.path))))
            var sources = [[String: Any]]()
            for line in snapshot.data.split(separator: 0x0A) {
                let event = try #require(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
                #expect(event["schema_version"] as? String == "marmot-forensics-audit/v4")
                if let kind = event["kind"] as? [String: Any], kind["type"] as? String == "source_context",
                   let source = kind["source"] as? [String: Any] {
                    sources.append(source)
                }
            }
            let source = try #require(sources.first)
            #expect(source["hardware_model"] as? String == "iPhone17,3")
            #expect(source["platform"] as? String == "ios")
            #expect(source["app_version"] as? String == "test-v4")
            for field in ["device_label", "device_name", "account_label"] {
                #expect(source[field] == nil)
            }
            try await client.marmot.shutdownAndClose()
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }
}

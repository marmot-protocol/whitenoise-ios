import Foundation
import Testing
@testable import darkmatter_ios
@testable import MarmotKit

struct PrivacySecuritySettingsProjectionTests {
    @Test func auditRowsPrecomputeDisplayStrings() {
        let files = [
            AuditLogFileFfi(
                accountRef: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef9999",
                path: "/tmp/audit-1.jsonl",
                fileName: "audit-1.jsonl",
                sizeBytes: 1_536,
                modifiedAtMs: nil
            )
        ]

        let row = AuditFileRowProjection.rows(from: files)[0]

        #expect(row.id == "/tmp/audit-1.jsonl")
        #expect(row.fileName == "audit-1.jsonl")
        #expect(row.path == "/tmp/audit-1.jsonl")
        #expect(row.detailText == "\(ByteCountFormatter.string(fromByteCount: 1_536, countStyle: .file)) - 12345678...abcdef")
    }

    @Test func privacySecurityViewRendersPrecomputedRows() throws {
        // Data + loading moved to the view model (Phase 4); the view renders
        // `ForEach(model.auditFileRows)`. Scrape the model for the precomputed-row
        // type + projection loading (not raw FFI).
        let source = try sourceString("darkmatter-ios/Settings/PrivacySecuritySettingsViewModel.swift")

        #expect(source.contains("var auditFileRows: [AuditFileRow] = []"))
        #expect(source.contains("try await appState.privacySecuritySettingsProjection()"))
        #expect(source.contains("try await appState.auditLogFileRows()"))
        #expect(!source.contains("@State private var auditFiles: [AuditLogFileFfi]"))
        #expect(!source.contains("auditFileDetails("))
        #expect(!source.contains("ForEach(auditFiles"))
    }

    @Test func marmotClientLoadsPrivacySettingsProjectionOffMainActor() throws {
        let source = try sourceString("darkmatter-ios/Core/MarmotClient.swift")

        #expect(source.matches(#"func privacySecuritySettingsProjection\(\) async throws -> PrivacySecuritySettingsProjection \{[\s\S]*Task\.detached\(priority: \.utility\)"#))
        #expect(source.matches(#"func auditFileRows\(\) async throws -> \[AuditFileRow\] \{[\s\S]*Task\.detached\(priority: \.utility\)"#))
    }

    private func sourceString(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}

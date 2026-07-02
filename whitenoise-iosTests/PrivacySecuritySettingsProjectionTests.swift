import Foundation
import Testing
@testable import whitenoise_ios
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
}

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

    @Test func auditRowsKeepTheFilesModifiedTime() {
        let file = AuditLogFileFfi(accountRef: "account", path: "/tmp/a.jsonl", fileName: "a.jsonl",
                                   sizeBytes: 1, modifiedAtMs: 1_799_999_999_000)
        #expect(AuditFileRowProjection.rows(from: [file])[0].modifiedAtMs == file.modifiedAtMs)
    }

    @Test func retentionCutoffIsThatManyDaysBeforeNowInMilliseconds() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let nowMs = UInt64(now.timeIntervalSince1970 * 1_000)
        #expect(AuditLogRetentionPresentation.cutoffMs(days: 7, now: now) == nowMs - 7 * 86_400_000)
        #expect(AuditLogRetentionPresentation.cutoffMs(days: 1, now: now) > AuditLogRetentionPresentation.cutoffMs(days: 7, now: now))
    }

    @Test func auditRowsListNewestCaptureFirstRegardlessOfFileName() {
        func file(_ name: String, _ modifiedAtMs: UInt64?) -> AuditLogFileFfi {
            AuditLogFileFfi(accountRef: "account", path: "/tmp/\(name)", fileName: name,
                            sizeBytes: 1, modifiedAtMs: modifiedAtMs)
        }
        let files = [
            file("audit-a-v5.jsonl", 1_000),
            file("audit-z-v5.jsonl", 3_000),
            file("audit-undated.jsonl", nil),
            file("audit-m-v5-seg000002.jsonl", 2_000),
            file("audit-b-v5.jsonl", 2_000)
        ]

        let names = AuditFileRowProjection.rows(from: files).map(\.fileName)

        #expect(names == [
            "audit-z-v5.jsonl",
            "audit-b-v5.jsonl",
            "audit-m-v5-seg000002.jsonl",
            "audit-a-v5.jsonl",
            "audit-undated.jsonl"
        ])
    }
}

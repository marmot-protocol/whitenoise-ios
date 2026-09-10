import Foundation
import MarmotKit
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticLogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data

    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

nonisolated struct DiagnosticLogSnapshot: Sendable {
    let fileName: String
    let data: Data
}

nonisolated enum DiagnosticLogExport {
    enum ExportError: Error {
        case noLogs
        case fileChangedDuringRead
    }

    static func fileForExport(in files: [AuditLogFileFfi], path: String? = nil) throws -> AuditLogFileFfi {
        let file: AuditLogFileFfi?
        if let path {
            file = files.first { $0.path == path && $0.sizeBytes > 0 }
        } else {
            file = latestFile(in: files)
        }
        guard let file else { throw ExportError.noLogs }
        return file
    }

    static func latestFile(in files: [AuditLogFileFfi]) -> AuditLogFileFfi? {
        files.filter { $0.sizeBytes > 0 }.max { left, right in
            let leftTime = left.modifiedAtMs ?? 0
            let rightTime = right.modifiedAtMs ?? 0
            if leftTime != rightTime { return leftTime < rightTime }
            return left.path < right.path
        }
    }

    static func snapshot(file: AuditLogFileFfi) throws -> DiagnosticLogSnapshot {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file.path))
        defer { try? handle.close() }
        // Keep one inode open across rotation; capture only bytes present at the start.
        let length = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        var remaining = length
        var data = Data()
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: Int(min(remaining, 1024 * 1024))) ?? Data()
            guard !chunk.isEmpty else { throw ExportError.fileChangedDuringRead }
            data.append(chunk)
            remaining -= UInt64(chunk.count)
        }
        // Never silently truncate a record caught mid-write. The caller can retry.
        guard !data.isEmpty, data.last == 0x0A else { throw ExportError.fileChangedDuringRead }
        return DiagnosticLogSnapshot(fileName: file.fileName, data: data)
    }
}

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

nonisolated struct DiagnosticLogShareFile: Identifiable, Sendable {
    let url: URL
    var id: URL { url }
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

    static func writeShareFile(
        _ snapshot: DiagnosticLogSnapshot,
        in root: URL = FileManager.default.temporaryDirectory
    ) throws -> DiagnosticLogShareFile {
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        let directory = root.appendingPathComponent("diagnostic-log-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: protection)
        let name = URL(fileURLWithPath: snapshot.fileName).lastPathComponent
        let url = directory.appendingPathComponent(["", "/", ".", ".."].contains(name) ? "audit.jsonl" : name)
        do {
            try snapshot.data.write(to: url, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes(protection, ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return DiagnosticLogShareFile(url: url)
    }

    static func removeShareFile(_ file: DiagnosticLogShareFile) {
        try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
    }

    /// Reads `file`, retrying briefly when a write lands mid-read.
    static func snapshotRetrying(file: AuditLogFileFfi) async throws -> DiagnosticLogSnapshot {
        for attempt in 0..<3 {
            do {
                return try snapshot(file: file)
            } catch ExportError.fileChangedDuringRead where attempt < 2 {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        throw ExportError.fileChangedDuringRead
    }

    // MARK: - Recent logs as one archive

    /// How far back a bundled export reaches, in whole 24-hour steps from now.
    enum Window: Int, CaseIterable, Identifiable, Sendable {
        case oneDay = 1, twoDays, threeDays

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .oneDay: L10n.string("Last 24 Hours")
            case .twoDays: L10n.string("Last 48 Hours")
            case .threeDays: L10n.string("Last 72 Hours")
            }
        }

        func cutoffMs(now: Date) -> UInt64 {
            let nowMs = UInt64(max(0, now.timeIntervalSince1970 * 1_000))
            let span = UInt64(rawValue) * 86_400_000
            return nowMs > span ? nowMs - span : 0
        }
    }

    /// Non-empty logs written to within `window`, newest first. A file with
    /// no modification time can't be placed in a window, so it is left out.
    static func files(in files: [AuditLogFileFfi], changedWithin window: Window, now: Date) -> [AuditLogFileFfi] {
        let cutoff = window.cutoffMs(now: now)
        return files
            .filter { file in file.sizeBytes > 0 && (file.modifiedAtMs.map { $0 >= cutoff } ?? false) }
            .sorted { left, right in
                let leftTime = left.modifiedAtMs ?? 0
                let rightTime = right.modifiedAtMs ?? 0
                return leftTime != rightTime ? leftTime > rightTime : left.path < right.path
            }
    }

    /// One safe, distinct entry name per file. Accounts keep separate log
    /// directories, so two files can share a name.
    static func archiveEntryNames(_ fileNames: [String]) -> [String] {
        var used: Set<String> = []
        return fileNames.map { raw in
            let last = URL(fileURLWithPath: raw).lastPathComponent
            let name = ["", "/", ".", ".."].contains(last) ? "audit.jsonl" : last
            let url = URL(fileURLWithPath: name)
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var candidate = name
            var index = 2
            while used.contains(candidate) {
                candidate = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
                index += 1
            }
            used.insert(candidate)
            return candidate
        }
    }

    static func archiveBaseName(window: Window, now: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let day = now.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day())
        return "white-noise-audit-logs-\(day)-last-\(window.rawValue * 24)h"
    }

    /// Copies each file into a protected folder and has iOS zip it. Files are
    /// read one at a time, so only one log is in memory at once.
    static func writeArchive(
        files: [AuditLogFileFfi],
        baseName: String,
        in root: URL = FileManager.default.temporaryDirectory,
        read: (AuditLogFileFfi) async throws -> DiagnosticLogSnapshot
    ) async throws -> DiagnosticLogShareFile {
        guard !files.isEmpty else { throw ExportError.noLogs }
        let manager = FileManager.default
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        let directory = root.appendingPathComponent("diagnostic-log-archive-\(UUID().uuidString)", isDirectory: true)
        let staging = directory.appendingPathComponent(baseName, isDirectory: true)
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: protection)
            try manager.setAttributes(protection, ofItemAtPath: directory.path)
            for (file, name) in zip(files, archiveEntryNames(files.map(\.fileName))) {
                try Task.checkCancellation()
                let snapshot = try await read(file)
                try snapshot.data.write(to: staging.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
            }
            let archive = directory.appendingPathComponent("\(baseName).zip")
            try zipDirectory(staging, to: archive)
            // The picker exposes this file, so it must not outlive a lock unprotected.
            try manager.setAttributes(protection, ofItemAtPath: archive.path)
            try? manager.removeItem(at: staging)
            return DiagnosticLogShareFile(url: archive)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    /// iOS writes a zip of a folder when it is read for uploading.
    private static func zipDirectory(_ directory: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading, error: &coordinationError) { zipped in
            do {
                try FileManager.default.copyItem(at: zipped, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
    }
}

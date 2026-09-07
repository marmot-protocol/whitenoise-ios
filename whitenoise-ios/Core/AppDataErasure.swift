import Darwin
import Foundation

nonisolated enum AppDataErasure {
    static let runtimeLockName = ".marmot-runtime.lock"

    /// MDK's root lease must retain its inode while the app and NSE can open it.
    static func eraseClosedRuntime(at root: URL) throws {
        var rootMetadata = stat()
        guard root.path != "/", lstat(root.path, &rootMetadata) == 0,
              rootMetadata.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.EINVAL) }
        let lock = root.appendingPathComponent(runtimeLockName)
        let descriptor = open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else { throw POSIXError(.EINVAL) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EBUSY) }
        defer { flock(descriptor, LOCK_UN) }
        for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            if child.lastPathComponent != runtimeLockName { try FileManager.default.removeItem(at: child) }
        }
    }

    static func clearContainerFiles() throws {
        let manager = FileManager.default
        let directories = [FileManager.SearchPathDirectory.cachesDirectory, .applicationSupportDirectory, .documentDirectory]
        for directory in directories {
            guard let url = manager.urls(for: directory, in: .userDomainMask).first,
                  manager.fileExists(atPath: url.path) else { continue }
            for child in try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try manager.removeItem(at: child)
            }
        }
        for child in try manager.contentsOfDirectory(at: manager.temporaryDirectory, includingPropertiesForKeys: nil) {
            try manager.removeItem(at: child)
        }
    }
}

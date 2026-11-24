import Darwin
import Foundation

@MainActor
enum AvatarCacheErasure {
    private static var activeErasures = 0
    static var isInProgress: Bool { activeErasures > 0 }
    private(set) static var generation = 0
    static func begin() {
        activeErasures += 1
        generation += 1
        NativeAvatarImageCache.shared.removeAll()
    }
    static func end() { activeErasures -= 1 }
}

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

    static func clearContainerFiles(fileManager: FileManager = .default) throws {
        let directories = [FileManager.SearchPathDirectory.cachesDirectory, .applicationSupportDirectory, .documentDirectory]
        var urlsToClear = directories.compactMap { fileManager.urls(for: $0, in: .userDomainMask).first }
        urlsToClear.append(fileManager.temporaryDirectory)
        if let sharedCaches = AppContainerConfig.sharedBase(fileManager: fileManager)?
            .appendingPathComponent("Library/Caches", isDirectory: true) {
            // Clears shared extension caches (such as NotificationAvatars) without
            // touching `White Noise/Marmot/.marmot-runtime.lock`.
            urlsToClear.append(sharedCaches)
        }
        for url in urlsToClear where fileManager.fileExists(atPath: url.path) {
            for child in try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try fileManager.removeItem(at: child)
            }
        }
    }
}

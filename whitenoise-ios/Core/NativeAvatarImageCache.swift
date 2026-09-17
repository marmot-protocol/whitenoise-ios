import UIKit

/// A bounded pixel handoff between visible views, never a second avatar source or disk cache.
@MainActor
final class NativeAvatarImageCache {
    static let shared = NativeAvatarImageCache()

    private struct Key: Hashable {
        let account: String
        let generation: Int
        let reference: String
        let revision: UInt64
    }

    private var images: [Key: UIImage] = [:]
    private var recency: [Key] = []
    private let capacity: Int

    init(capacity: Int = 64) { self.capacity = max(1, capacity) }

    func image(account: String, generation: Int, reference: String, revision: UInt64) -> UIImage? {
        let key = Key(account: account, generation: generation, reference: reference, revision: revision)
        guard let image = images[key] else { return nil }
        touch(key)
        return image
    }

    func insert(_ image: UIImage, account: String, generation: Int, reference: String, revision: UInt64) {
        let key = Key(account: account, generation: generation, reference: reference, revision: revision)
        images[key] = image
        touch(key)
        while recency.count > capacity { images.removeValue(forKey: recency.removeFirst()) }
    }

    func removeAll() {
        images.removeAll()
        recency.removeAll()
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

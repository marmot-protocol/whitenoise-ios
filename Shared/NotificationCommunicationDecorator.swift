import CryptoKit
import Foundation
import ImageIO
import Intents
import Synchronization
import UniformTypeIdentifiers
import UserNotifications

/// Decorates message notifications as communication notifications so the
/// system renders the sender's avatar (initials monogram when no image is
/// available). Avatar fetching is bounded and cached in the app group so a
/// slow avatar host can never delay notification delivery.
nonisolated enum NotificationCommunicationDecorator {
    static let maxAvatarBytes = 512 * 1024
    static let avatarRequestTimeout: TimeInterval = 4
    /// Hard wall-clock bound per avatar resolution. The URLRequest timeout
    /// restarts across redirects and resolved endpoints, so delivery races
    /// this deadline instead and abandons the fetch when it loses.
    static let avatarDeadline: Duration = .seconds(3)
    /// Aggregate wall-clock the NSE may spend across all avatar fetches in
    /// one wake; each fetch's deadline is clamped to what remains.
    static let avatarAggregateBudget: Duration = .seconds(6)
    static let maxCachedAvatars = 32
    static let maxAvatarPixelDimension = 4_096
    static let maxAvatarPixelCount = 16_777_216
    static let maxAvatarFrames = 8

    /// Per-fetch deadline under an aggregate budget, `nil` once the budget is
    /// exhausted. Clamping to the remainder is what makes the budget a hard
    /// bound — a loop that only checks elapsed time before each fetch can
    /// overshoot by a full per-fetch deadline.
    static func avatarFetchDeadline(
        elapsed: Duration,
        budget: Duration = avatarAggregateBudget,
        perFetch: Duration = avatarDeadline
    ) -> Duration? {
        let remaining = budget - elapsed
        guard remaining > .zero else { return nil }
        return min(perFetch, remaining)
    }

    static func decorated(
        _ content: UNNotificationContent,
        presentation: LocalNotificationPresentation,
        avatarData: Data?
    ) -> UNNotificationContent {
        guard let senderName = presentation.senderName, !senderName.isEmpty else { return content }
        let handle = personHandleValue(for: presentation)
        let safeAvatarData = avatarData.flatMap { isAllowedAvatarData($0) ? $0 : nil }
        let sender = INPerson(
            personHandle: INPersonHandle(value: handle, type: .unknown),
            nameComponents: nil,
            displayName: senderName,
            image: safeAvatarData.map(INImage.init(imageData:)),
            contactIdentifier: nil,
            customIdentifier: handle
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: presentation.body,
            speakableGroupName: presentation.isGroupConversation
                ? INSpeakableString(spokenPhrase: presentation.title)
                : nil,
            conversationIdentifier: presentation.threadIdentifier,
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
        do {
            return try content.updating(from: intent)
        } catch {
            return content
        }
    }

    /// Older versions donated decrypted previews and sender identities to the
    /// system interaction store. Current notification styling uses only
    /// `content.updating(from:)`, but a destructive wipe must still clear that
    /// historical residue.
    static func deleteAllDonatedInteractions() async -> Bool {
        await withCheckedContinuation { continuation in
            INInteraction.deleteAll { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    /// Stable per-sender identity: the account id survives display-name and
    /// nickname changes and keeps two same-named senders in one thread apart.
    private static func personHandleValue(for presentation: LocalNotificationPresentation) -> String {
        "\(presentation.threadIdentifier):\(presentation.senderAccountIdHex ?? presentation.senderName ?? "")"
    }

    // MARK: - Bounded, cached avatar bytes

    /// `pictureUrl` is re-validated even though presentations carry it
    /// pre-sanitized — the decorator is its own egress chokepoint.
    static func avatarData(for pictureUrl: String?, deadline: Duration = avatarDeadline) async -> Data? {
        guard let pictureUrl, let url = ContentSanitizer.imageURL(pictureUrl) else { return nil }
        if let cached = cachedAvatarData(for: url) { return cached }
        return await withDeadline(deadline) {
            guard let fetched = await boundedFetch(url) else { return nil }
            storeCachedAvatar(fetched, for: url)
            return fetched
        }
    }

    /// Cache-only read for paths that must never wait on the network — the
    /// foreground presenter enqueues immediately and warms the cache instead.
    static func cachedAvatarData(forPictureUrl pictureUrl: String?) -> Data? {
        guard let pictureUrl, let url = ContentSanitizer.imageURL(pictureUrl) else { return nil }
        return cachedAvatarData(for: url)
    }

    private static let warmsInFlight = Mutex<Set<String>>([])

    /// Application-level bound on concurrent warm fetches. Per-URL dedup alone
    /// lets many distinct slow hosts each hold a detached task (DNS is not
    /// interruptible), so the set itself is capped; warms beyond it are
    /// dropped — the cache is opportunistic.
    static let maxConcurrentWarms = 4

    static func claimWarmSlot(
        _ key: String,
        in inFlight: inout Set<String>,
        limit: Int = maxConcurrentWarms
    ) -> Bool {
        guard inFlight.count < limit, !inFlight.contains(key) else { return false }
        inFlight.insert(key)
        return true
    }

    /// Fills the avatar cache off the delivery path so the next presentation
    /// of this sender carries an image. Deduplicates concurrent warms per URL
    /// and caps how many may run at once.
    static func warmAvatarCache(for pictureUrl: String?) {
        guard let pictureUrl, let url = ContentSanitizer.imageURL(pictureUrl) else { return }
        guard cachedAvatarData(for: url) == nil else { return }
        let key = url.absoluteString
        let claimed = warmsInFlight.withLock { inFlight in
            claimWarmSlot(key, in: &inFlight)
        }
        guard claimed else { return }
        Task.detached(priority: .utility) {
            defer { _ = warmsInFlight.withLock { $0.remove(key) } }
            guard let fetched = await boundedFetch(url) else { return }
            storeCachedAvatar(fetched, for: url)
        }
    }

    private struct DeadlineRace {
        var resumed = false
        var cancelled = false
        var continuation: CheckedContinuation<Data?, Never>?
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
    }

    /// Resumes with the work's value, `nil` at the deadline, or `nil` when the
    /// caller is cancelled — whichever comes first. A task group can't provide
    /// this bound: it awaits every child at scope exit, so a fetch stalled in
    /// non-cancellable DNS would hold the caller past `cancelAll()`. Every
    /// losing side is cancelled — deadline and caller-cancellation wins cancel
    /// the fetch so peer-controlled work can't accumulate, and a work win
    /// cancels the sleeping timer.
    static func withDeadline(
        _ deadline: Duration,
        work: @escaping @Sendable () async -> Data?
    ) async -> Data? {
        let race = Mutex(DeadlineRace())

        @Sendable func finish(_ value: Data?, cancellingWork: Bool) {
            let resolved: (CheckedContinuation<Data?, Never>, Task<Void, Never>?, Task<Void, Never>?)? =
                race.withLock { state in
                    guard !state.resumed, let continuation = state.continuation else { return nil }
                    state.resumed = true
                    state.continuation = nil
                    return (continuation, cancellingWork ? state.work : nil, state.timer)
                }
            guard let (continuation, workTask, timerTask) = resolved else { return }
            workTask?.cancel()
            timerTask?.cancel()
            continuation.resume(returning: value)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.withLock { state in
                    state.continuation = continuation
                }
                // The caller may have been cancelled before the continuation
                // existed; the flag records it so the resume isn't lost.
                if race.withLock({ $0.cancelled }) {
                    finish(nil, cancellingWork: false)
                    return
                }
                let workTask = Task.detached {
                    let value = await work()
                    finish(value, cancellingWork: false)
                }
                let timerTask = Task.detached {
                    try? await Task.sleep(for: deadline)
                    finish(nil, cancellingWork: true)
                }
                let alreadyResumed = race.withLock { state in
                    state.work = workTask
                    state.timer = timerTask
                    return state.resumed
                }
                if alreadyResumed {
                    // A cancellation that won between the continuation being
                    // stored and the handles registering resumed with neither
                    // handle to cancel — the fetch would run to completion
                    // behind an already-returned caller. (After a work win
                    // both cancels are no-ops.)
                    workTask.cancel()
                    timerTask.cancel()
                }
            }
        } onCancel: {
            race.withLock { $0.cancelled = true }
            finish(nil, cancellingWork: true)
        }
    }

    private static func boundedFetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = avatarRequestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        guard let (data, response) = try? await PinnedHTTPSFetcher.fetch(
            request,
            maximumResponseBytes: maxAvatarBytes
        ) else { return nil }
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              isAllowedAvatarData(data)
        else { return nil }
        return data
    }

    /// `INImage(imageData:)` accepts arbitrary bytes and defers interpretation
    /// to system services. Sniff the payload locally and allow only decodable
    /// raster image sources before caching or crossing that boundary.
    static func isAllowedAvatarData(_ data: Data) -> Bool {
        guard !data.isEmpty,
              data.count <= maxAvatarBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeIdentifier = CGImageSourceGetType(source),
              let type = UTType(typeIdentifier as String),
              type.conforms(to: .image),
              !type.conforms(to: .svg)
        else { return false }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0, frameCount <= maxAvatarFrames else { return false }
        var frameDimensions: [(width: Int, height: Int)] = []
        frameDimensions.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
            else { return false }
            frameDimensions.append((width, height))
        }
        return avatarMetadataIsAllowed(frameDimensions: frameDimensions)
    }

    static func avatarMetadataIsAllowed(
        frameDimensions: [(width: Int, height: Int)],
        maxDimension: Int = maxAvatarPixelDimension,
        maxTotalPixels: Int = maxAvatarPixelCount,
        maxFrames: Int = maxAvatarFrames
    ) -> Bool {
        guard !frameDimensions.isEmpty, frameDimensions.count <= maxFrames else { return false }
        var totalPixels = 0
        for frame in frameDimensions {
            guard frame.width > 0,
                  frame.height > 0,
                  frame.width <= maxDimension,
                  frame.height <= maxDimension
            else { return false }
            let (framePixels, multiplicationOverflow) = frame.width.multipliedReportingOverflow(by: frame.height)
            let (nextTotal, additionOverflow) = totalPixels.addingReportingOverflow(framePixels)
            guard !multiplicationOverflow, !additionOverflow, nextTotal <= maxTotalPixels else { return false }
            totalPixels = nextTotal
        }
        return true
    }

    private static var cacheDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppContainerConfig.appGroupIdentifier)?
            .appendingPathComponent("Library/Caches/NotificationAvatars", isDirectory: true)
    }

    private static func cacheFileURL(for url: URL) -> URL? {
        guard let cacheDirectory else { return nil }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(name)
    }

    /// Cache entries expire so a changed image behind a stable URL converges;
    /// a stale hit reads as a miss and the re-fetch overwrites the file.
    static let avatarCacheLifetime: TimeInterval = 7 * 24 * 3600

    private static func cachedAvatarData(for url: URL, now: Date = Date()) -> Data? {
        guard let file = cacheFileURL(for: url),
              let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              now.timeIntervalSince(modified) < avatarCacheLifetime,
              let data = try? Data(contentsOf: file),
              isAllowedAvatarData(data)
        else { return nil }
        return data
    }

    private static func storeCachedAvatar(_ data: Data, for url: URL) {
        guard let cacheDirectory, let file = cacheFileURL(for: url) else { return }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        pruneCache(in: cacheDirectory)
    }

    private static func pruneCache(in directory: URL) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ), files.count > maxCachedAvatars else { return }
        let sorted = files.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        }
        for file in sorted.prefix(files.count - maxCachedAvatars) {
            try? manager.removeItem(at: file)
        }
    }
}

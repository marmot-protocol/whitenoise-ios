import Foundation
import ImageIO
import Intents
import UniformTypeIdentifiers
import UserNotifications

/// Decorates message notifications as communication notifications so the
/// system renders the sender's initials monogram. Never initiates remote HTTPS
/// fetches on push wakes or notification arrival.
nonisolated enum NotificationCommunicationDecorator {
    static let maxAvatarBytes = 512 * 1024
    /// Hard wall-clock bound per avatar resolution.
    static let avatarDeadline: Duration = .seconds(3)
    /// Aggregate wall-clock the NSE may spend across all avatar resolutions in
    /// one wake; each resolution's deadline is clamped to what remains.
    static let avatarAggregateBudget: Duration = .seconds(6)
    static let maxAvatarPixelDimension = 4_096
    static let maxAvatarPixelCount = 16_777_216
    static let maxAvatarFrames = 8
    /// Distinct sender pictures resolved per wake, in arrival order.
    static let maxAvatarFetchesPerWake = 3

    /// The sender pictures one wake fetches: each distinct URL once, in the
    /// order its presentation arrived, at most `limit` of them.
    static func avatarURLs(
        for presentations: [LocalNotificationPresentation],
        limit: Int = maxAvatarFetchesPerWake
    ) -> [String] {
        var distinct: [String] = []
        for presentation in presentations {
            if let url = presentation.senderPictureUrl, !distinct.contains(url) {
                distinct.append(url)
            }
        }
        return Array(distinct.prefix(limit))
    }

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

    // MARK: - Zero-egress avatar resolution

    /// Notification presentation never initiates remote HTTPS fetches to
    /// peer-controlled hosts. Returns `nil` so the communication intent falls
    /// back to the sender's initials monogram until MDK exposes opaque local
    /// avatar references on `NotificationUserFfi`.
    static func avatarData(
        for pictureUrl: String?,
        deadline: Duration = avatarDeadline
    ) async -> Data? {
        _ = (pictureUrl, deadline)
        return nil
    }

    /// `INImage(imageData:)` accepts arbitrary bytes and defers interpretation
    /// to system services. Sniff the payload locally and allow only decodable
    /// raster image sources before crossing that boundary.
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
}

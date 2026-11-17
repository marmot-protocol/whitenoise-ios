import Foundation
import MarmotKit

/// Copy for the "Chats on this device" step, written for people who already use
/// White Noise or another Marmot app elsewhere.
nonisolated struct AccountSetupDeviceNoticePresentation {
    enum Evidence: Equatable {
        case noneFound, unknown
        /// MDK found messaging keys published by another installation of this account.
        case otherApps(latestPublication: Date?)
    }

    /// `nil` until MDK has checked for other installations.
    let evidence: Evidence?

    init(_ notice: OnboardingSingleDeviceNoticeFfi?, now: Date = .now) {
        switch notice?.discovery {
        case nil: evidence = nil
        case .noneFound: evidence = .noneFound
        case .unknown: evidence = .unknown
        case .otherInstallationPossible:
            // Relays supply these dates: skip a missing (0) one and a future one, which MDK flags separately.
            let latest = notice?.otherPackages
                .map(\.publishedAt)
                .filter { $0 > 0 && TimeInterval(Int64(clamping: $0)) <= now.timeIntervalSince1970 }
                .max()
            evidence = .otherApps(latestPublication: latest.map {
                Date(timeIntervalSince1970: TimeInterval(Int64(clamping: $0)))
            })
        }
    }

    var actionTitle: String {
        evidence == .noneFound ? L10n.string("Continue") : L10n.string("Continue anyway")
    }

    /// `nil` until MDK has checked. "Didn't find" is deliberate: finding nothing does not
    /// prove there is no other installation.
    var finding: String? {
        switch evidence {
        case nil: return nil
        case .noneFound: return L10n.string("We didn’t find messaging keys from another app or device.")
        case .unknown:
            return L10n.string("We couldn’t check whether this account uses another app or device for messaging.")
        case .otherApps(let latest?):
            let date = latest.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: AppLanguage.currentLocale))
            return L10n.formatted(
                "We found messaging keys this account published from another app or device, most recently on %@.",
                date
            )
        case .otherApps(nil):
            return L10n.string("We found messaging keys this account published from another app or device.")
        }
    }

    /// Each sign-in is a separate installation with its own chats; the copy must not
    /// suggest this device is added, linked or synced to another one.
    var explanation: [String] {
        switch evidence {
        case .noneFound: []
        case .otherApps:
            [
                L10n.string("This device will have its own separate chats. Chats in the other app stay there and won’t appear here."),
                L10n.string("When someone starts a new chat with you, it may arrive in either app.")
            ]
        case .unknown, nil:
            [L10n.string("If you use another app for messaging, this device will have its own separate chats, and chats in that app won’t appear here.")]
        }
    }
}

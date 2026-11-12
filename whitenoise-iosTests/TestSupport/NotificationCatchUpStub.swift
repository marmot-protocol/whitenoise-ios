@testable import whitenoise_ios

/// Lets a test replace the notification coordinator's catch-up calls after its
/// app state exists. A call with no replacement runs the live one.
@MainActor
final class NotificationCatchUpStub {
    var onCatchUp: (@MainActor () async throws -> Void)?
    var onConnectivityRestored: (@MainActor () async throws -> Void)?

    var calls: NotificationCatchUpCalls {
        NotificationCatchUpCalls(
            catchUpAccounts: { [weak self] host in
                if let onCatchUp = self?.onCatchUp {
                    try await onCatchUp()
                } else {
                    try await NotificationCatchUpCalls.live.catchUpAccounts(host)
                }
            },
            notifyConnectivityRestored: { [weak self] host in
                if let onConnectivityRestored = self?.onConnectivityRestored {
                    try await onConnectivityRestored()
                } else {
                    try await NotificationCatchUpCalls.live.notifyConnectivityRestored(host)
                }
            }
        )
    }
}

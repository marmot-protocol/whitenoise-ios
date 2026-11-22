import Foundation

/// Whether the active account wrote a message. MDK records a message this
/// account sent from another of its devices, live or imported with chat history,
/// as `received`; it is still the user's own and shows as sent. Delivery state
/// stays with this device's own sends (`direction == "sent"`).
nonisolated enum MessageOwnership {
    static func isMine(direction: String, sender: String, myAccountId: String?) -> Bool {
        if direction == "sent" { return true }
        guard let me = Hex.normalized32Bytes(myAccountId),
              let author = Hex.normalized32Bytes(sender) else { return false }
        return author == me
    }
}

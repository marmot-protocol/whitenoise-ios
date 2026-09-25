struct SenderProfileTarget: Identifiable, Hashable {
    let npub: String
    var id: String { npub }

    init?(senderAccountIdHex: String) {
        guard let npub = NostrProfileReference.npub(fromAccountIdHex: senderAccountIdHex) else { return nil }
        self.npub = npub
    }
}

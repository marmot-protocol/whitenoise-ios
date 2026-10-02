import SwiftUI

nonisolated enum ChatListIdentifierSearch {
    static func profileNpub(for resolution: RecipientResolutionState) -> String? {
        guard case .resolved(let resolved) = resolution else { return nil }
        return NostrProfileReference.npub(fromAccountIdHex: resolved.accountIdHex)
    }
}

struct ChatListIdentifierProfileRouting: ViewModifier {
    @Environment(AppState.self) private var appState
    let query: String
    let identifierQuery: RecipientQueryModel
    let onOpenProfile: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: query) { _, query in
                identifierQuery.text = query
                identifierQuery.queryChanged(using: appState)
            }
            .onChange(of: identifierQuery.resolution) { _, resolution in
                guard let npub = ChatListIdentifierSearch.profileNpub(for: resolution) else { return }
                onOpenProfile()
                appState.presentProfile(npub: npub)
            }
    }
}

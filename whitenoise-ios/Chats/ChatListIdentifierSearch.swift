import SwiftUI
import MarmotKit

nonisolated enum ChatListIdentifierSearch {
    enum Destination: Equatable {
        case profile(npub: String)
        case chat(groupIdHex: String)
    }

    static func profileNpub(for resolution: RecipientResolutionState) -> String? {
        guard case .resolved(let resolved) = resolution else { return nil }
        return NostrProfileReference.npub(fromAccountIdHex: resolved.accountIdHex)
    }

    static func destination(
        for resolution: RecipientResolutionState,
        snapshots: [RecipientGroupSnapshot],
        myAccountIdHex: String?
    ) -> Destination? {
        guard case .resolved(let resolved) = resolution,
              let npub = NostrProfileReference.npub(fromAccountIdHex: resolved.accountIdHex)
        else { return nil }
        guard let myAccountIdHex,
              resolved.accountIdHex.lowercased() != myAccountIdHex.lowercased()
        else { return .profile(npub: npub) }
        let directChats = snapshots.filter {
            $0.isDirectChat(withMember: resolved.accountIdHex, myAccountIdHex: myAccountIdHex)
        }
        guard directChats.count == 1, let directChat = directChats.first else {
            return .profile(npub: npub)
        }
        return .chat(groupIdHex: directChat.groupIdHex)
    }
}

struct ChatListIdentifierProfileRouting: ViewModifier {
    private struct RouteKey: Equatable {
        let resolution: RecipientResolutionState
        let runtimeGeneration: Int
    }

    @Environment(AppState.self) private var appState
    @State private var directory = RecipientDirectory()
    let query: String
    let identifierQuery: RecipientQueryModel
    let onOpenProfile: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: query) { _, query in
                identifierQuery.text = query
                identifierQuery.queryChanged(using: appState)
            }
            .task(id: RouteKey(
                resolution: identifierQuery.resolution,
                runtimeGeneration: appState.runtimeGeneration
            )) {
                await route(identifierQuery.resolution)
            }
    }

    private func route(_ resolution: RecipientResolutionState) async {
        guard ChatListIdentifierSearch.profileNpub(for: resolution) != nil else { return }
        let accountRef = appState.activeAccountRef
        let runtimeGeneration = appState.runtimeGeneration
        await directory.load(using: appState, force: !directory.isLoadInFlight)
        guard !Task.isCancelled,
              identifierQuery.resolution == resolution,
              appState.activeAccountRef == accountRef,
              appState.runtimeGeneration == runtimeGeneration,
              let destination = ChatListIdentifierSearch.destination(
                  for: resolution,
                  snapshots: directory.loadError == nil ? directory.snapshots : [],
                  myAccountIdHex: appState.activeAccount?.accountIdHex
              )
        else { return }
        switch destination {
        case .profile(let npub):
            onOpenProfile()
            appState.presentProfile(npub: npub)
        case .chat(let groupIdHex):
            appState.presentChat(groupIdHex: groupIdHex)
        }
    }
}

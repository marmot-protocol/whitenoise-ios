import MarmotKit
import SwiftUI

enum OnboardingRecoveryPresentation {
    static func readyProfiles(
        accounts: [AccountSummaryFfi],
        recoveredInSession: [AccountSummaryFfi],
        recoveryIDs: Set<String>,
        unfinishedIDs: Set<String>
    ) -> [AccountSummaryFfi] {
        var profiles = accounts
        let knownIDs = Set(accounts.map(\.accountIdHex))
        // Preserve a confirmed reset if its following account refresh failed.
        profiles += recoveredInSession.filter { !knownIDs.contains($0.accountIdHex) }
        return profiles.filter {
            $0.localSigning && $0.signedOut
                && !recoveryIDs.contains($0.accountIdHex)
                && !unfinishedIDs.contains($0.accountIdHex)
        }
    }
}

struct OnboardingRecoveryProfileSummary: View {
    @Environment(AppState.self) private var appState
    let account: AccountSummaryFfi
    @State private var identityHeight: CGFloat = 64

    var body: some View {
        let profile = appState.cachedProfile(forAccountIdHex: account.accountIdHex)
        let identity = IdentityPresentation.resolve(
            accountIdHex: account.accountIdHex,
            knownName: AppState.resolvedKnownDisplayName(profile: profile, projectedName: nil, localAccountLabel: nil)
        )
        let hasName = identity.source == .name
        let name = hasName ? identity.text : L10n.string("Unnamed profile")
        HStack(alignment: .top, spacing: 12) {
            AvatarBubble(
                seed: account.accountIdHex,
                title: name,
                pictureURL: ContentSanitizer.imageURL(profile?.picture),
                placeholderSystemImage: hasName ? nil : "person.fill"
            )
            .frame(width: identityHeight, height: identityHeight)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: name).font(.title2.weight(.semibold))
                if let npub = IdentityPresentation.canonicalNpub(accountIdHex: account.accountIdHex) {
                    CopyableValueChip(
                        display: IdentityFormatter.short(npub, head: 14, tail: 4),
                        copyValue: npub,
                        valueName: L10n.string("npub"),
                        usesFilledStyle: true
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { identityHeight = $0 }
        }
        .task(id: appState.runtimeGeneration) {
            appState.warmProfileProjection(forAccountIdHex: account.accountIdHex, refreshAfterLoad: false)
        }
    }
}

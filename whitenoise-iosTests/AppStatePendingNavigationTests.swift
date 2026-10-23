import Testing
import Foundation
@testable import whitenoise_ios
@testable import MarmotKit

/// Pending profile/chat navigation and visible-chat tracking on `AppState`.
@MainActor
struct AppStatePendingNavigationTests {
    @Test func routingIsBackedByFocusedNavigationState() async throws {
        let appState = AppState.test()
        appState.accountStore.accounts = [
            AccountSummaryFfi(label: "account-a", accountIdHex: hex("aa"), localSigning: true, signedOut: false, running: true),
            AccountSummaryFfi(label: "account-b", accountIdHex: hex("bb"), localSigning: true, signedOut: false, running: true)
        ]
        appState.activeAccountRef = "account-a"

        appState.presentProfile(npub: "npub1example")
        #expect(appState.navigation.pendingProfile == AppState.ProfileLink(npub: "npub1example"))
        #expect(appState.pendingProfile == appState.navigation.pendingProfile)

        appState.presentChat(
            groupIdHex: "group-a",
            accountRef: "account-b",
            messageIdHex: "  message-a  "
        )
        #expect(appState.activeAccountRef == "account-b")
        #expect(appState.navigation.pendingChatId == "group-a")
        #expect(appState.navigation.pendingChatAccountRef == "account-b")
        #expect(appState.navigation.pendingChatMessageIdHex == "message-a")

        appState.clearPendingChat()
        #expect(appState.navigation.pendingChatId == nil)
        #expect(appState.navigation.pendingChatAccountRef == nil)
        #expect(appState.navigation.pendingChatMessageIdHex == nil)
    }

    @Test func deferredChatPresentationPublishesNavigationIntentImmediately() async throws {
        let appState = AppState.test()
        appState.accountStore.accounts = [
            AccountSummaryFfi(
                label: "account-a",
                accountIdHex: hex("aa"),
                localSigning: true,
                signedOut: false,
                running: true
            )
        ]
        appState.activeAccountRef = "account-a"

        DeferredChatPresentation.present(groupIdHex: "group-a", using: appState)

        #expect(appState.navigation.pendingChatId == "group-a")
    }

    @Test func routedChatIgnoresMissingOrSignedOutAccounts() async throws {
        let appState = AppState.test()
        appState.accountStore.accounts = [
            AccountSummaryFfi(label: "account-a", accountIdHex: hex("aa"), localSigning: true, signedOut: false, running: true),
            AccountSummaryFfi(label: "account-b", accountIdHex: hex("bb"), localSigning: true, signedOut: true, running: false)
        ]
        appState.activeAccountRef = "account-a"

        appState.presentChat(groupIdHex: "group-stale", accountRef: "removed-account")

        #expect(appState.activeAccountRef == "account-a")
        #expect(appState.navigation.pendingChatId == nil)

        appState.presentChat(groupIdHex: "group-signed-out", accountRef: "account-b")

        #expect(appState.activeAccountRef == "account-a")
        #expect(appState.navigation.pendingChatId == nil)
    }

    @Test func visibleChatRouteTracksAccountAndClearsOnlyMatchingRoute() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "account-a"

        let route = appState.beginViewingChat(groupIdHex: "group-a")

        #expect(route == VisibleChatRoute(accountRef: "account-a", groupIdHex: "group-a"))
        #expect(appState.visibleChat == route)
        #expect(appState.isViewingNotificationDestination(accountRef: "account-a", groupIdHex: "group-a"))
        #expect(!appState.isViewingNotificationDestination(accountRef: "account-a", groupIdHex: "group-b"))

        appState.setAppSceneActive(false)
        #expect(!appState.isViewingNotificationDestination(accountRef: "account-a", groupIdHex: "group-a"))

        appState.setAppSceneActive(true)
        appState.endViewingChat(VisibleChatRoute(accountRef: "account-b", groupIdHex: "group-a"))
        #expect(appState.visibleChat == route)

        if let route {
            appState.endViewingChat(route)
        }
        #expect(appState.visibleChat == nil)
    }
}

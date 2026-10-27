import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct NativePushRegistrationPolicyTests {

    @Test func enabledAccountsAreSyncedAcrossAllLocalAccounts() {
        let accounts = [
            AccountSummaryFfi(label: "account-a", accountIdHex: hex("11"), localSigning: true, signedOut: false, running: true),
            AccountSummaryFfi(label: "account-b", accountIdHex: hex("22"), localSigning: true, signedOut: false, running: true),
            AccountSummaryFfi(label: "account-c", accountIdHex: hex("33"), localSigning: true, signedOut: false, running: true)
        ]
        let settings = [
            "account-a": NotificationSettingsFfi(
                accountRef: "account-a",
                accountIdHex: hex("11"),
                localNotificationsEnabled: true,
                nativePushEnabled: true
            ),
            "account-b": NotificationSettingsFfi(
                accountRef: "account-b",
                accountIdHex: hex("22"),
                localNotificationsEnabled: true,
                nativePushEnabled: false
            )
        ]

        let enabled = NativePushRegistrationPolicy.enabledAccountRefs(accounts: accounts) { settings[$0] }

        #expect(enabled == ["account-a"])
    }

    @Test func enabledAccountRefsCanUseCapturedAccountLabels() {
        let settings = [
            "account-a": Self.settings(nativePushEnabled: true),
            "account-b": Self.settings(nativePushEnabled: false)
        ]

        let enabled = NativePushRegistrationPolicy.enabledAccountRefs(
            accountRefs: ["account-a", "account-b", "account-c"]
        ) { settings[$0] }

        #expect(enabled == ["account-a"])
    }

    @Test func remoteTokenIsRequestedOnlyWhenEnabledAccountsLackAToken() {
        #expect(NativePushRegistrationPolicy.shouldRequestRemoteToken(
            accountRefs: ["account-a"],
            currentToken: nil
        ))
        #expect(NativePushRegistrationPolicy.shouldRequestRemoteToken(
            accountRefs: ["account-a"],
            currentToken: ""
        ))
        #expect(!NativePushRegistrationPolicy.shouldRequestRemoteToken(
            accountRefs: ["account-a"],
            currentToken: "abc123"
        ))
        #expect(!NativePushRegistrationPolicy.shouldRequestRemoteToken(
            accountRefs: [],
            currentToken: nil
        ))
    }

    private static func settings(nativePushEnabled: Bool) -> NotificationSettingsFfi {
        NotificationSettingsFfi(
            accountRef: "account",
            accountIdHex: hex("11"),
            localNotificationsEnabled: true,
            nativePushEnabled: nativePushEnabled
        )
    }

}

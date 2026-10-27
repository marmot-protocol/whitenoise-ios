import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct GroupPushDebugPresentationTests {
    @Test func tokenSummaryIncludesTotalActiveAndStaleCounts() {
        let info = GroupPushDebugInfoFfi(
            totalTokenCount: 3,
            activeTokenCount: 2,
            staleTokenCount: 1,
            missingRelayHintCount: 1,
            lastTokenListUpdatedAtMs: nil,
            localRegistration: LocalPushRegistrationDebugFfi(
                registered: true,
                shareable: true,
                localNotificationsEnabled: true,
                nativePushEnabled: true,
                localLeafIndex: 7,
                localTokenCached: true
            ),
            tokens: []
        )

        #expect(GroupPushDebugPresentation.tokenSummary(for: info) == "3 total, 2 active, 1 stale")
        #expect(GroupPushDebugPresentation.missingRelayHintSummary(for: info) == "1 missing relay hint")
        #expect(GroupPushDebugPresentation.localRegistrationSummary(for: info.localRegistration) == "Registered, native push on, token cached")
        #expect(GroupPushDebugPresentation.platformLabel(.apns) == "APNS")
        #expect(GroupPushDebugPresentation.platformLabel(.fcm) == "FCM")
    }

    @Test func tokenSummaryPluralizesZeroAndMultipleCounts() {
        let info = GroupPushDebugInfoFfi(
            totalTokenCount: 0,
            activeTokenCount: 0,
            staleTokenCount: 0,
            missingRelayHintCount: 2,
            lastTokenListUpdatedAtMs: nil,
            localRegistration: LocalPushRegistrationDebugFfi(
                registered: false,
                shareable: false,
                localNotificationsEnabled: false,
                nativePushEnabled: false,
                localLeafIndex: nil,
                localTokenCached: false
            ),
            tokens: []
        )

        #expect(GroupPushDebugPresentation.tokenSummary(for: info) == "0 total, 0 active, 0 stale")
        #expect(GroupPushDebugPresentation.missingRelayHintSummary(for: info) == "2 missing relay hints")
        #expect(GroupPushDebugPresentation.localRegistrationSummary(for: info.localRegistration) == "Not registered, native push off, no local token")
    }
}

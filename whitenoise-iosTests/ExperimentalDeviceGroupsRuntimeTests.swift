import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

@Suite(.marmotRuntimeConcurrencyLimit)
struct ExperimentalDeviceGroupsRuntimeTests {
    /// A library without `dev-device-groups` refuses the experimental
    /// constructor; asking for it must still open the runtime, ordinarily.
    @Test func requestingDeviceGroupsOpensWhicheverRuntimeTheLibraryCanRun() async throws {
        let capable = MarmotKitVersion.features.split(separator: ",").contains("dev-device-groups")
        try await withTestClient(deviceGroupsRequested: true) { client in
            #expect(client.deviceGroupsRequested)
            #expect(client.deviceGroupsEnabled == capable)
        }
        try await withTestClient { client in
            #expect(!client.deviceGroupsEnabled)
        }
    }
}

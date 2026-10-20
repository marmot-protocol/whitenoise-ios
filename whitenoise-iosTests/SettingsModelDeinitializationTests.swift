import Foundation
import XCTest
@testable import whitenoise_ios

private enum SettingsDeinitializationContext {
    @TaskLocal static var isReleasing = false
}

@MainActor
final class SettingsModelDeinitializationTests: XCTestCase {
    func testDestinationModelsReleaseFromSynchronousTaskLocalScope() async {
        await checkRelease([
            ("Profile", { ProfileEditViewModel() }),
            ("Profile Keys", { IdentityViewModel() }),
            ("Notifications", {
                NotificationSettingsViewModel(previewDefaults: nil, mutedChatMentionsDefaults: nil)
            }),
            ("Privacy and Developer Tools", { PrivacySecuritySettingsViewModel() }),
            ("Relays", { RelaysViewModel() }),
            ("Quarantined Groups", { QuarantinedGroupsViewModel() }),
            ("Donate", {
                // Construct the real owned dependencies without starting payment preparation,
                // networking, or Keychain reads/writes.
                DonateViewModel(config: DonationBuildConfig(
                    environment: .staging,
                    serviceURL: URL(string: "https://example.com")!,
                    merchantIdentifier: "merchant.test"
                ))
            }),
        ])
    }

    func testSupportEntryAndOwnedModelsReleaseFromSynchronousTaskLocalScope() async {
        // Includes NewChatFlowViewModel and its directory, search, selection, starter,
        // and prewarmer models, all owned by Settings' Support row.
        await checkRelease([("Support", { SupportChatEntryModel() })])
    }

    private func checkRelease(_ factories: [(String, @MainActor () -> AnyObject)]) async {
        let released = expectation(description: "Settings models released")

        // Settings navigation can discard destinations from a synchronous
        // SwiftUI callback with task-local values but no Swift task.
        DispatchQueue.main.async {
            withUnsafeCurrentTask { XCTAssertNil($0) }
            SettingsDeinitializationContext.$isReleasing.withValue(true) {
                for (name, makeModel) in factories {
                    XCTContext.runActivity(named: name) { _ in
                        var model: AnyObject? = makeModel()
                        weak var releasedModel = model
                        XCTAssertNotNil(releasedModel)

                        model = nil

                        XCTAssertNil(releasedModel)
                        XCTAssertTrue(SettingsDeinitializationContext.isReleasing)
                    }
                }
            }
            XCTAssertFalse(SettingsDeinitializationContext.isReleasing)
            released.fulfill()
        }

        await fulfillment(of: [released], timeout: 5)
    }
}

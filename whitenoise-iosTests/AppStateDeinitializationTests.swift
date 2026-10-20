import Foundation
import MarmotKit
import XCTest
@testable import whitenoise_ios

private enum AppStateDeinitializationContext {
    @TaskLocal static var isReleasing = false
}

@MainActor
final class AppStateDeinitializationTests: XCTestCase {
    func testMediaLoaderAndAppStateReleaseFromSynchronousTaskLocalScope() async {
        let released = expectation(description: "Media loader, AppState and its stores released")

        // SwiftUI can release its environment from a synchronous callback with
        // task-local values but no Swift task. Older runtimes crash on an actor hop here.
        DispatchQueue.main.async {
            withUnsafeCurrentTask { XCTAssertNil($0) }
            AppStateDeinitializationContext.$isReleasing.withValue(true) {
                var state: AppState? = .test(
                    notifications: AppNotifications(),
                    accountDefaults: IsolatedAccountDefaults.make(),
                    erasureDefaults: IsolatedAccountDefaults.make()
                )
                state?.pendingAccountSetup = AccountSetupModel(snapshot: OnboardingSnapshotFfi(
                    accountIdHex: String(repeating: "a", count: 64), recoveryEpoch: nil, revision: 1,
                    ready: false, steps: [], proposal: nil, singleDeviceNotice: nil, cancellationPending: false
                ))
                state?.conversationOpenPerformance = ConversationOpenPerformance(start: .now, ticket: nil)
                // Gallery callbacks can retain the environment until SwiftUI releases the loader.
                var loader: ConversationMediaLoader? = ConversationMediaLoader { [state] _ in
                    XCTAssertNotNil(state)
                    XCTFail("Releasing the loader must not request media")
                    return Data()
                }
                weak var releasedLoader = loader
                weak var releasedState = state
                weak var releasedErasureState = state?.erasureState
                weak var releasedDraftStore = state?.conversationDraftStore
                weak var releasedNotifications = state?.notificationCoordinator
                weak var releasedSetup = state?.pendingAccountSetup

                state = nil
                XCTAssertNotNil(releasedState)
                loader = nil

                XCTAssertNil(releasedLoader)
                XCTAssertNil(releasedState)
                XCTAssertNil(releasedErasureState)
                XCTAssertNil(releasedDraftStore)
                XCTAssertNil(releasedNotifications)
                XCTAssertNil(releasedSetup)
                XCTAssertTrue(AppStateDeinitializationContext.isReleasing)
            }
            XCTAssertFalse(AppStateDeinitializationContext.isReleasing)
            released.fulfill()
        }

        await fulfillment(of: [released], timeout: 5)
    }
}

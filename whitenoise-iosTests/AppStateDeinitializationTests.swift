import Foundation
import MarmotKit
import XCTest
@testable import whitenoise_ios

private enum AppStateDeinitializationContext {
    @TaskLocal static var isReleasing = false
}

@MainActor
final class AppStateDeinitializationTests: XCTestCase {
    func testReleaseFromSynchronousTaskLocalScope() async {
        let released = expectation(description: "AppState and its stores released")

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
                weak var releasedState = state
                weak var releasedErasureState = state?.erasureState
                weak var releasedDraftStore = state?.conversationDraftStore
                weak var releasedNotifications = state?.notificationCoordinator
                weak var releasedSetup = state?.pendingAccountSetup

                state = nil

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

import Foundation
import XCTest
@testable import whitenoise_ios

private enum ProfileEditDeinitializationContext {
    @TaskLocal static var isReleasing = false
}

@MainActor
final class ProfileEditViewModelDeinitializationTests: XCTestCase {
    func testProfileModelReleasesFromSynchronousTaskLocalScope() async {
        let released = expectation(description: "Profile model released")

        // Settings navigation can discard the profile destination from a synchronous
        // SwiftUI callback with task-local values but no Swift task.
        DispatchQueue.main.async {
            withUnsafeCurrentTask { XCTAssertNil($0) }
            ProfileEditDeinitializationContext.$isReleasing.withValue(true) {
                var model: ProfileEditViewModel? = ProfileEditViewModel()
                weak var releasedModel = model
                XCTAssertNotNil(releasedModel)

                model = nil

                XCTAssertNil(releasedModel)
                XCTAssertTrue(ProfileEditDeinitializationContext.isReleasing)
            }
            XCTAssertFalse(ProfileEditDeinitializationContext.isReleasing)
            released.fulfill()
        }

        await fulfillment(of: [released], timeout: 5)
    }
}

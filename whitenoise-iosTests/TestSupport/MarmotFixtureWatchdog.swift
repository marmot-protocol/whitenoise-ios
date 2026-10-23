import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

enum MarmotFixtureWatchdog {
    static let deadlineOnlyADeadlockCanReach = Duration.seconds(300)

    static func start(_ description: Comment, breaking client: MarmotClient) -> Task<Void, Error> {
        Task {
            try await Task.sleep(for: deadlineOnlyADeadlockCanReach)
            Issue.record(description)
            try await client.marmot.shutdownAndClose()
        }
    }
}

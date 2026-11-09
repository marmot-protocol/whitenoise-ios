@testable import whitenoise_ios
import MarmotKit

/// Runs the production finalized-stream read and records which timeline records
/// a `StreamWatcher` decoded, in order.
@MainActor
final class FinalizedStreamReadCounter {
    private(set) var decodedMessageIds: [String] = []

    var read: @MainActor (TimelineMessageRecordFfi) -> String? {
        { [self] record in
            decodedMessageIds.append(record.messageIdHex)
            return StreamWatcher.finalizedStreamId(in: record)
        }
    }
}

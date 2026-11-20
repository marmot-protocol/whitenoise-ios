import Testing
@testable import whitenoise_ios

/// "Read more" must survive the timeline rebuilding a row under another id.
@Suite struct ExpandedMessageBodiesTests {
    @Test func aSentMessageStaysOpenWhenItReturnsUnderItsDurableRowID() {
        // Opened while its optimistic send row was on screen; after the window
        // evicts it, the message comes back as `msg:<message id>`.
        var bodies = ExpandedMessageBodies()
        bodies.insert(rowID: "local-send-7", messageID: "abc")

        #expect(bodies.contains(rowID: "msg:abc", messageID: "abc"))
        #expect(bodies.contains(rowID: "local-send-7", messageID: "abc"))
    }

    @Test func aRowWithoutAMessageIDOpensOnlyItself() {
        var bodies = ExpandedMessageBodies()
        bodies.insert(rowID: "local-send-7", messageID: "")

        #expect(bodies.contains(rowID: "local-send-7", messageID: ""))
        #expect(!bodies.contains(rowID: "local-send-8", messageID: ""))
        #expect(!bodies.contains(rowID: "msg:abc", messageID: "abc"))
    }
}

import Foundation
import Testing
@testable import whitenoise_ios

/// Tests for the reply-envelope id walker the ElectrumX transport uses to
/// filter server notifications from JSON-RPC replies. Fixtures are ported
/// from whitenoise-linux `scripts/nc_shim_selftest.c` (79447095f2).
///
/// The selftest's frame-overflow fixtures (two-fragment attack, oversize
/// single frame) have no direct analog: Network.framework owns RFC 6455
/// framing, masking, and defragmentation, so the C shim's byte-level length
/// arithmetic does not exist in this port. The hard message cap the shim
/// applied is carried over as a post-delivery size check in the transport.
struct ElectrumXTransportTests {
    private func messageId(_ envelope: String) -> Int? {
        ElectrumXTransport.messageId(in: Data(envelope.utf8))
    }

    @Test func nestedIdReturnsTopLevelId() {
        // The reviewer's fixture: a nested "id" must not win over the
        // envelope's own id.
        #expect(messageId("{\"result\":{\"id\":99},\"id\":2}") == 2)
    }

    @Test func whitespaceAroundIdIsTolerated() {
        #expect(messageId("{\"id\" : 2,\"result\":null}") == 2)
    }

    @Test func missingIdReturnsNil() {
        #expect(messageId("{\"result\":null}") == nil)
    }

    @Test func idInsideAStringValueIsIgnored() {
        #expect(messageId("{\"data\":\"has \\\"id\\\": inside\",\"id\":7}") == 7)
    }

    @Test func errorEnvelopeIdIsExtracted() {
        let envelope = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,\"message\":\"nope\"},\"id\":42}"
        #expect(messageId(envelope) == 42)
    }

    @Test func notificationWithoutIdReturnsNil() {
        // ElectrumX subscription push: must not be mistaken for a reply.
        let envelope = "{\"method\":\"blockchain.headers.subscribe\",\"params\":[{\"hex\":\"...\",\"height\":1}]}"
        #expect(messageId(envelope) == nil)
    }

    @Test func nonIntegerIdReturnsNil() {
        #expect(messageId("{\"id\":null,\"result\":null}") == nil)
        #expect(messageId("{\"id\":\"2\",\"result\":null}") == nil)
    }

    @Test func negativeIdIsExtracted() {
        #expect(messageId("{\"id\":-3,\"result\":null}") == -3)
    }

    @Test func unbalancedEnvelopeReturnsNil() {
        #expect(messageId("}}{\"id\":2}") == nil)
    }

    @Test func hardMessageCapMatchesUpstream() {
        // NC_HARD_FRAME_CAP in nc_shim.c.
        #expect(ElectrumXTransport.hardMessageCap == 16 * 1024 * 1024)
    }
}

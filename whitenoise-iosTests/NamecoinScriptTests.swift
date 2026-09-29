import Foundation
import Testing
@testable import whitenoise_ios

/// Pure-function tests for the Namecoin script assembly, scripthash
/// derivation, and name-op vout decoding — the parts of the resolver that
/// never touch the ElectrumX network. Ported from whitenoise-linux
/// `tests/app/namecoin_test.odin`.
struct NamecoinScriptTests {
    // MARK: - script assembly + scripthash

    @Test func scriptLayoutForShortName() {
        // Short names use the direct-length push opcode: the first byte
        // after OP_NAME_UPDATE is the name length, not a PUSHDATA opcode.
        let name = Array("d/example".utf8)
        let script = NamecoinScript.buildNameIndexScript(name: name)

        // OP_NAME_UPDATE (0x53) | len=9 | name bytes | 0x00 (empty value push)
        // | OP_2DROP (0x6d) | OP_DROP (0x75) | OP_RETURN (0x6a)
        #expect(script[0] == 0x53)
        #expect(script[1] == UInt8(name.count))
        for (index, byte) in name.enumerated() {
            #expect(script[2 + index] == byte)
        }
        let tail = 2 + name.count
        #expect(script[tail] == 0x00)
        #expect(script[tail + 1] == 0x6d)
        #expect(script[tail + 2] == 0x75)
        #expect(script[tail + 3] == 0x6a)
    }

    @Test func scriptHashMatchesReferenceVector() {
        // SHA-256("5309642f6578616d706c65006d756a"), byte-reversed hex.
        // Cross-checked against the ElectrumX protocol definition and the
        // linux port's derivation.
        let name = Array("d/example".utf8)
        let script = NamecoinScript.buildNameIndexScript(name: name)
        #expect(script.map { String(format: "%02x", $0) }.joined() == "5309642f6578616d706c65006d756a")
        #expect(
            NamecoinScript.electrumScriptHash(script: script)
                == "92f51fe51fa9c53ea842325c9c63a9b8592b3f64c7477b6e538a64d80cd8c0ac"
        )
    }

    @Test func scriptHashIsDeterministic() {
        let name = Array("d/example".utf8)
        let script = NamecoinScript.buildNameIndexScript(name: name)
        let first = NamecoinScript.electrumScriptHash(script: script)
        let second = NamecoinScript.electrumScriptHash(script: script)
        #expect(first == second)
        #expect(first.count == 64)
    }

    // MARK: - name-op vout decoding

    @Test func parseOpNameUpdate() {
        // OP_NAME_UPDATE <push "d/example"> <push "hello"> <trailer>
        let name = Array("d/example".utf8)
        let value = Array("hello".utf8)
        var script: [UInt8] = [0x53, UInt8(name.count)] + name + [UInt8(value.count)] + value
        script.append(contentsOf: [0x6d, 0x75, 0x6a])

        let parsed = NamecoinScript.parseNameScript(script)
        #expect(parsed?.name == "d/example")
        #expect(parsed?.value == "hello")
    }

    @Test func parseOpNameFirstUpdate() {
        // OP_NAME_FIRSTUPDATE <push name> <push 20-byte rand> <push value> <trailer>
        let name = Array("d/mstrofnone".utf8)
        let value = Array("{\"nostr\":\"deadbeef\"}".utf8)
        var script: [UInt8] = [0x52, UInt8(name.count)] + name
        script.append(20) // rand push length
        script.append(contentsOf: [UInt8](repeating: 0xAA, count: 20))
        script.append(UInt8(value.count))
        script.append(contentsOf: value)
        script.append(contentsOf: [0x6d, 0x6d, 0x75, 0x6a])

        let parsed = NamecoinScript.parseNameScript(script)
        #expect(parsed?.name == "d/mstrofnone")
        #expect(parsed?.value == "{\"nostr\":\"deadbeef\"}")
    }

    @Test func parseRejectsOpNameNew() {
        // OP_NAME_NEW (0x51) carries no visible value.
        let script: [UInt8] = [0x51, 0x02, 0xaa, 0xbb, 0x75, 0x6a]
        #expect(NamecoinScript.parseNameScript(script) == nil)
    }

    @Test func hexDecodeRoundtrip() {
        let input: [UInt8] = [0x00, 0x53, 0xff, 0xa1, 0x0d]
        let asHex = input.map { String(format: "%02x", $0) }.joined()
        #expect(NamecoinScript.hexDecode(asHex) == input)
        #expect(NamecoinScript.hexDecode("0xnothex") == nil)
        #expect(NamecoinScript.hexDecode("abc") == nil) // odd length
    }

    @Test func extractNameValueMatches() {
        // A vout: OP_NAME_UPDATE push "d/x" push "V".
        let script: [UInt8] = [0x53, 3, 0x64, 0x2f, 0x78, 1, 0x56, 0x6d, 0x75, 0x6a]
        let asHex = script.map { String(format: "%02x", $0) }.joined()
        // A second vout that pays a p2pkh; the front-door filter must skip it.
        let p2pkh = "76a914aabbccddeeff112233445566778899aabbccddee88ac"

        #expect(NamecoinScript.extractNameValue(vouts: [p2pkh, asHex], name: "d/x") == "V")
        // Non-matching name returns nil.
        #expect(NamecoinScript.extractNameValue(vouts: [asHex], name: "d/y") == nil)
    }
}

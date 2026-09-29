import CryptoKit
import Foundation

/// Namecoin OP_NAME_UPDATE script assembly and OP_NAME_* vout parsing.
///
/// ElectrumX indexes Namecoin names by the scripthash of a canonical
/// OP_NAME_UPDATE-shaped script over the name bytes; the resolver hashes
/// that here to derive the key it sends to `blockchain.scripthash.get_history`.
/// Once history comes back, the same helpers decode the OP_NAME_UPDATE or
/// OP_NAME_FIRSTUPDATE vout the transaction carries and pull the raw name
/// value JSON out. Both layouts share the OP_NAME_NEW envelope; only
/// FIRSTUPDATE wedges a 20-byte HASH160 commitment between the name and
/// the value push.
///
/// Ported from whitenoise-linux `app/namecoin_script.odin` (commit
/// 79447095f2) so a value payload produced against any of the parallel
/// ports roundtrips through this parser.
nonisolated enum NamecoinScript {
    /// Namecoin script opcodes used by the name-index script.
    static let opNameNew: UInt8 = 0x51
    static let opNameFirstUpdate: UInt8 = 0x52
    static let opNameUpdate: UInt8 = 0x53
    static let op2Drop: UInt8 = 0x6d
    static let opDrop: UInt8 = 0x75
    static let opReturn: UInt8 = 0x6a
    static let opPushData1: UInt8 = 0x4c
    static let opPushData2: UInt8 = 0x4d
    static let opPushData4: UInt8 = 0x4e

    /// HASH160 commitment length in an OP_NAME_FIRSTUPDATE vout, per namecore
    /// consensus rules.
    static let firstUpdateRandLength = 20

    /// Builds the OP_NAME_UPDATE name-index script for `name` bytes:
    /// `OP_NAME_UPDATE <push(name)> <push(empty)> OP_2DROP OP_DROP OP_RETURN`.
    static func buildNameIndexScript(name: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [opNameUpdate]
        pushData(&out, name)
        pushData(&out, [])
        out.append(contentsOf: [op2Drop, opDrop, opReturn])
        return out
    }

    static func pushData(_ out: inout [UInt8], _ data: [UInt8]) {
        let n = data.count
        if n < Int(opPushData1) {
            out.append(UInt8(n))
        } else if n <= 0xff {
            out.append(contentsOf: [opPushData1, UInt8(n)])
        } else if n <= 0xffff {
            out.append(contentsOf: [opPushData2, UInt8(n & 0xff), UInt8((n >> 8) & 0xff)])
        } else {
            out.append(contentsOf: [
                opPushData4,
                UInt8(n & 0xff),
                UInt8((n >> 8) & 0xff),
                UInt8((n >> 16) & 0xff),
                UInt8((n >> 24) & 0xff),
            ])
        }
        out.append(contentsOf: data)
    }

    /// ElectrumX scripthash: SHA-256 of the script, byte-reversed, lowercase
    /// hex. Every ElectrumX server keys `blockchain.scripthash.get_history`
    /// by this exact digest. Computed locally — the resolver never trusts the
    /// server for name-to-script derivation.
    static func electrumScriptHash(script: [UInt8]) -> String {
        let digest = SHA256.hash(data: script)
        return digest.reversed().map { String(format: "%02x", $0) }.joined()
    }

    /// Reads one push from `script` at `offset`; returns the pushed bytes plus
    /// the position just past it. `nil` for a malformed / truncated push.
    static func readPush(_ script: [UInt8], offset: Int) -> (data: ArraySlice<UInt8>, next: Int)? {
        guard offset < script.count else { return nil }
        let op = script[offset]
        if op == 0x00 {
            return (script[offset ..< offset], offset + 1)
        }
        if op < opPushData1 {
            let length = Int(op)
            let end = offset + 1 + length
            guard end <= script.count else { return nil }
            return (script[(offset + 1) ..< end], end)
        }
        if op == opPushData1 {
            guard offset + 2 <= script.count else { return nil }
            let length = Int(script[offset + 1])
            let end = offset + 2 + length
            guard end <= script.count else { return nil }
            return (script[(offset + 2) ..< end], end)
        }
        if op == opPushData2 {
            guard offset + 3 <= script.count else { return nil }
            let length = Int(script[offset + 1]) | (Int(script[offset + 2]) << 8)
            let end = offset + 3 + length
            guard end <= script.count else { return nil }
            return (script[(offset + 3) ..< end], end)
        }
        if op == opPushData4 {
            guard offset + 5 <= script.count else { return nil }
            let length = Int(script[offset + 1])
                | (Int(script[offset + 2]) << 8)
                | (Int(script[offset + 3]) << 16)
                | (Int(script[offset + 4]) << 24)
            let end = offset + 5 + length
            guard end >= 0, end <= script.count else { return nil }
            return (script[(offset + 5) ..< end], end)
        }
        return nil
    }

    /// Decodes one Namecoin name-op vout into its `(name, value)` pair.
    /// Accepts both value-carrying layouts:
    ///
    ///     OP_NAME_FIRSTUPDATE <name> <rand> <value> OP_2DROP OP_2DROP OP_DROP <p2pkh>
    ///     OP_NAME_UPDATE      <name> <value>        OP_2DROP OP_DROP        <p2pkh>
    ///
    /// OP_NAME_NEW carries no value here; returns `nil` for it.
    static func parseNameScript(_ script: [UInt8]) -> (name: String, value: String)? {
        guard let op = script.first,
              op == opNameUpdate || op == opNameFirstUpdate
        else { return nil }
        guard let namePush = readPush(script, offset: 1) else { return nil }
        var offset = namePush.next
        if op == opNameFirstUpdate {
            guard let randPush = readPush(script, offset: offset),
                  randPush.data.count == firstUpdateRandLength
            else { return nil }
            offset = randPush.next
        }
        guard let valuePush = readPush(script, offset: offset) else { return nil }
        return (String(decoding: namePush.data, as: UTF8.self), String(decoding: valuePush.data, as: UTF8.self))
    }

    /// Decodes one lowercase hex string into bytes; `nil` on any malformed
    /// nibble or odd length.
    static func hexDecode(_ string: String) -> [UInt8]? {
        let bytes = string.utf8
        guard bytes.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count / 2)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            guard let hi = hexNibble(bytes[index]),
                  let lo = hexNibble(bytes[bytes.index(after: index)])
            else { return nil }
            out.append(UInt8(hi << 4 | lo))
            index = bytes.index(index, offsetBy: 2)
        }
        return out
    }

    private static func hexNibble(_ byte: UInt8) -> Int? {
        switch byte {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"):
            Int(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a") ... UInt8(ascii: "f"):
            Int(byte - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A") ... UInt8(ascii: "F"):
            Int(byte - UInt8(ascii: "A")) + 10
        default:
            nil
        }
    }

    /// Walks `vouts` (each a hex-encoded scriptPubKey) and returns the raw name
    /// value string for the vout that carries `name`. `nil` when no vout matches.
    static func extractNameValue(vouts: [String], name: String) -> String? {
        for hexScript in vouts {
            // Cheap front-door: only 0x52 / 0x53 opcodes carry a value.
            guard hexScript.count >= 2,
                  hexScript[hexScript.startIndex] == "5",
                  hexScript[hexScript.index(after: hexScript.startIndex)] == "2"
                    || hexScript[hexScript.index(after: hexScript.startIndex)] == "3",
                  let bytes = hexDecode(hexScript),
                  let parsed = parseNameScript(bytes),
                  parsed.name == name
            else { continue }
            return parsed.value
        }
        return nil
    }
}

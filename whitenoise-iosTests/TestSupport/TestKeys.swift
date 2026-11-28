import Foundation

/// Generates unique, valid Nostr `nsec1...` keys for tests that touch the
/// process-shared iOS Simulator Keychain via `Marmot`.
///
/// Reusing a hardcoded `nsec` across concurrent tests causes cross-test
/// `.SecretNotFound` races whenever one test deletes or wipes that account's
/// Keychain entry while another test is still using the same identity.
enum TestKeys {
    private static let bech32Charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let bech32Generators = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]

    static func randomNsec() -> String {
        var rng = SystemRandomNumberGenerator()
        // Any 32-byte scalar with leading byte in 0x01...0xFE is strictly
        // within 1 <= k < n for secp256k1 (n starts with 0xFF...FE).
        var secret = [UInt8](repeating: 0, count: 32)
        secret[0] = UInt8.random(in: 1...254, using: &rng)
        for index in 1..<secret.count {
            secret[index] = UInt8.random(in: 0...255, using: &rng)
        }
        return encodeNsec(secret)
    }

    static func encodeNsec(_ secret32Bytes: [UInt8]) -> String {
        precondition(secret32Bytes.count == 32, "nsec secret must be 32 bytes")
        let hrp = "nsec"
        let words = convert8To5Bits(secret32Bytes)
        let checksum = createChecksum(hrp: hrp, words: words)
        let encoded = (words + checksum).map { bech32Charset[Int($0)] }
        return "\(hrp)1\(String(encoded))"
    }

    private static func convert8To5Bits(_ bytes: [UInt8]) -> [UInt8] {
        var acc = 0
        var bits = 0
        var out: [UInt8] = []
        out.reserveCapacity(52)
        for byte in bytes {
            acc = (acc << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(UInt8((acc >> bits) & 31))
            }
        }
        if bits > 0 {
            out.append(UInt8((acc << (5 - bits)) & 31))
        }
        return out
    }

    private static func createChecksum(hrp: String, words: [UInt8]) -> [UInt8] {
        var values: [UInt8] = hrp.unicodeScalars.map { UInt8($0.value >> 5) }
        values.append(0)
        values.append(contentsOf: hrp.unicodeScalars.map { UInt8($0.value & 31) })
        values.append(contentsOf: words)
        values.append(contentsOf: repeatElement(0, count: 6))
        let polymod = bech32Polymod(values) ^ 1
        return (0..<6).map { index in
            UInt8((polymod >> (5 * (5 - index))) & 31)
        }
    }

    private static func bech32Polymod(_ values: [UInt8]) -> Int {
        var checksum = 1
        for value in values {
            let top = checksum >> 25
            checksum = ((checksum & 0x1ffffff) << 5) ^ Int(value)
            for index in 0..<5 where ((top >> index) & 1) != 0 {
                checksum ^= bech32Generators[index]
            }
        }
        return checksum
    }
}

import Testing
@testable import whitenoise_ios

/// Regression coverage for issue #103: decoding `utsname.machine` bytes must not
/// trap when a byte has the high bit set (≥ 0x80, i.e. negative as `Int8`).
struct TelemetryMachineIdentifierTests {

    @Test func decodesAsciiMachineBytesIntoIdentifier() {
        let bytes: [Int8] = Array("iPhone17,1".utf8).map(Int8.init(bitPattern:)) + [0, 0, 0]
        #expect(TelemetryBuildConfig.machineIdentifier(fromMachineBytes: bytes) == "iPhone17,1")
    }

    @Test func decodesHighBitBytesWithoutTrapping() {
        // 0xC3 / 0x80 read back as Int8(-61) / Int8(-128). The old
        // `UInt8(value)` conversion traps on negative input; `UInt8(bitPattern:)`
        // must reinterpret the bits instead of crashing.
        let bytes: [Int8] = [Int8(bitPattern: 0xC3), Int8(bitPattern: 0x80), 0]
        #expect(TelemetryBuildConfig.machineIdentifier(fromMachineBytes: bytes) == "\u{00C3}\u{0080}")
    }

    @Test func emptyOrAllNulBytesReturnNil() {
        #expect(TelemetryBuildConfig.machineIdentifier(fromMachineBytes: []) == nil)
        #expect(TelemetryBuildConfig.machineIdentifier(fromMachineBytes: [0, 0, 0]) == nil)
    }
}

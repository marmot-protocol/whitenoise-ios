import Foundation
import Testing
@testable import whitenoise_ios

struct AppStateActivationGuardTests {
    @Test func activateAccountDeduplicatesInFlightReactivationBeforeAwaitingSignIn() throws {
        let source = try sourceString("whitenoise-ios/Core/AppState.swift")

        #expect(source.contains("private var activatingAccountRefs = Set<String>()"))

        // `activateAccount` reaches the concrete Marmot UniFFI client on the signed-out
        // reactivation path, so there is no cheap deterministic behavior seam for the
        // suspension window. Keep this source-level test focused on the invariant that
        // matters: the in-flight marker and cleanup must be installed before any await.
        let body = try functionSource(
            signature: "func activateAccount(_ accountRef: String) async",
            in: source
        )

        let activeGuard = try #require(body.range(of: "guard accountRef != activeAccountRef else { return }"))
        let accountLookup = try #require(body.range(
            of: "guard let account = accounts.first(where: { $0.label == accountRef }) else { return }"
        ))
        let inFlightGuard = try #require(body.range(
            of: "guard activatingAccountRefs.insert(accountRef).inserted else { return }"
        ))
        let cleanup = try #require(body.range(of: "defer { activatingAccountRefs.remove(accountRef) }"))
        let awaitRanges = ranges(of: "await ", in: body)

        #expect(activeGuard.lowerBound < accountLookup.lowerBound)
        #expect(accountLookup.lowerBound < inFlightGuard.lowerBound)
        #expect(inFlightGuard.lowerBound < cleanup.lowerBound)
        #expect(!awaitRanges.isEmpty)
        for awaitRange in awaitRanges {
            #expect(cleanup.upperBound <= awaitRange.lowerBound)
        }
    }

    private func sourceString(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func functionSource(signature: String, in source: String) throws -> Substring {
        let signatureRange = try #require(source.range(of: signature))
        let bodyStart = try #require(source[signatureRange.upperBound...].firstIndex(of: "{"))
        var depth = 0
        var index = bodyStart

        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return source[signatureRange.lowerBound...index]
                }
            default:
                break
            }
            index = source.index(after: index)
        }

        throw SourceFixtureError.missingClosingBrace(signature)
    }

    private func ranges(of needle: String, in text: Substring) -> [Range<Substring.Index>] {
        var result: [Range<Substring.Index>] = []
        var searchRange = text.startIndex..<text.endIndex

        while let range = text.range(of: needle, range: searchRange) {
            result.append(range)
            searchRange = range.upperBound..<text.endIndex
        }

        return result
    }

    private enum SourceFixtureError: Error {
        case missingClosingBrace(String)
    }
}

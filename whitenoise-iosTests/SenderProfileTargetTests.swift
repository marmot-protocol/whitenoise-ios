import Testing

@testable import whitenoise_ios

struct SenderProfileTargetTests {
    @Test func validSenderResolvesToItsNpub() throws {
        let target = try #require(SenderProfileTarget(
            senderAccountIdHex: "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c114166f89e50a34d86adeee9"
        ))
        #expect(target.npub == "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkd7y72z35mp4dam5svjhxk4")
        #expect(target.id == target.npub)
    }

    @Test(arguments: ["", "not-hex", String(repeating: "ab", count: 31)])
    func malformedSenderHasNoTarget(sender: String) {
        #expect(SenderProfileTarget(senderAccountIdHex: sender) == nil)
    }
}

import Testing
@testable import whitenoise_ios

struct MarmotKitBuildLabelTests {
    @Test func taggedBuildShowsVersionAndShortHash() {
        #expect(
            MarmotKitBuildLabel.text(
                tag: "marmotkit-v0.9.5",
                sha: "5729f6cde28323b3"
            ) == "MarmotKit v0.9.5 (5729f6cd)"
        )
    }

    @Test func sourceBuildOmitsVersionEvenWhenBuiltFromTaggedCommit() {
        #expect(
            MarmotKitBuildLabel.text(
                tag: "marmotkit-v0.9.5",
                sha: "5729f6cd-dirty"
            ) == "MarmotKit (5729f6cd)"
        )
    }

    @Test func untaggedCleanBuildOmitsVersion() {
        #expect(
            MarmotKitBuildLabel.text(
                tag: "",
                sha: "abcdef1234567890"
            ) == "MarmotKit (abcdef12)"
        )
    }
}

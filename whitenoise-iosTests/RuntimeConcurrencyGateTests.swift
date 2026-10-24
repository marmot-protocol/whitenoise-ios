import Testing

struct RuntimeConcurrencyGateTests {
    @Test(arguments: [(3, 1), (8, 2), (16, 4), (1, 1)])
    func permitsAreAQuarterOfTheCoresAndAtLeastOne(cores: Int, permits: Int) {
        #expect(marmotRuntimeGatePermits(environment: [:], activeProcessorCount: cores) == permits)
    }

    @Test func coreOverrideReplacesTheProcessorCount() {
        #expect(marmotRuntimeGatePermits(environment: ["WN_TEST_GATE_CORES": "3"], activeProcessorCount: 16) == 1)
        #expect(marmotRuntimeGatePermits(environment: ["WN_TEST_GATE_CORES": "32"], activeProcessorCount: 3) == 8)
    }

    @Test(arguments: ["", "three", "4.5", " 8"])
    func malformedOverrideFallsBackToTheProcessorCount(value: String) {
        #expect(marmotRuntimeGatePermits(environment: ["WN_TEST_GATE_CORES": value], activeProcessorCount: 16) == 4)
    }
}

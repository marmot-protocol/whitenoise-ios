import Testing

@MainActor
func waitForExpectation(
    pollingIntervalNanoseconds: UInt64 = 5_000_000,
    attempts: Int = 100,
    _ predicate: () -> Bool
) async throws {
    for _ in 0..<attempts {
        if predicate() { return }
        try await Task.sleep(nanoseconds: pollingIntervalNanoseconds)
    }
    #expect(predicate())
}

import Testing

struct WindowTestGateTests {
    private actor Occupancy {
        var active = 0
        var maximum = 0
        var completed = 0

        func enter() {
            active += 1
            maximum = max(maximum, active)
        }

        func leave() {
            active -= 1
            completed += 1
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func yieldingOperationsCannotOverlap() async throws {
        let gate = WindowTestGate()
        let occupancy = Occupancy()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    try await gate.run {
                        await occupancy.enter()
                        for _ in 0..<10 { await Task.yield() }
                        await occupancy.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await occupancy.maximum == 1)
        #expect(await occupancy.completed == 32)
    }

    @Test(.timeLimit(.minutes(1)))
    func throwingOperationReleasesTheNextOperation() async throws {
        enum ExpectedFailure: Error { case operation }
        let gate = WindowTestGate()
        await #expect(throws: ExpectedFailure.self) {
            try await gate.run { throw ExpectedFailure.operation }
        }
        let occupancy = Occupancy()
        try await gate.run { await occupancy.enter() }
        #expect(await occupancy.active == 1)
    }
}

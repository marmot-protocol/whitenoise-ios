import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

actor AsyncTestGate {
    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int = 1) {
        availablePermits = permits
    }

    func withLock<T>(_ operation: () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            availablePermits += 1
            return
        }
        waiters.removeFirst().resume()
    }
}

private let marmotRuntimeTestGate = AsyncTestGate(
    permits: max(1, ProcessInfo.processInfo.activeProcessorCount / 4)
)

struct MarmotRuntimeConcurrencyLimit: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        guard testCase != nil else { return try await function() }
        try await marmotRuntimeTestGate.withLock { try await function() }
    }
}

extension Trait where Self == MarmotRuntimeConcurrencyLimit {
    static var marmotRuntimeConcurrencyLimit: Self { Self() }
}

import Foundation
import MarmotKit

nonisolated struct NotificationSubscriptionRunner {
    let initialRetryDelayNanoseconds: UInt64
    let maximumRetryDelayNanoseconds: UInt64
    let subscribe: () async throws -> AsyncStream<NotificationUpdateFfi>
    let present: (NotificationUpdateFfi) async -> Void
    let reportError: (Error) async -> Void
    let sleep: (UInt64) async throws -> Void

    init(
        initialRetryDelayNanoseconds: UInt64,
        maximumRetryDelayNanoseconds: UInt64,
        subscribe: @escaping () async throws -> AsyncStream<NotificationUpdateFfi>,
        present: @escaping (NotificationUpdateFfi) async -> Void,
        reportError: @escaping (Error) async -> Void,
        sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.initialRetryDelayNanoseconds = initialRetryDelayNanoseconds
        self.maximumRetryDelayNanoseconds = maximumRetryDelayNanoseconds
        self.subscribe = subscribe
        self.present = present
        self.reportError = reportError
        self.sleep = sleep
    }

    func run() async {
        var retryDelay = initialRetryDelayNanoseconds

        while !Task.isCancelled {
            var deliveredNotification = false

            do {
                let updates = try await subscribe()
                for await update in updates {
                    guard !Task.isCancelled else { return }
                    deliveredNotification = true
                    retryDelay = initialRetryDelayNanoseconds
                    await present(update)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await reportError(error)
            }

            guard !Task.isCancelled else { return }

            do {
                try await sleep(retryDelay)
            } catch {
                return
            }

            if !deliveredNotification {
                retryDelay = nextDelay(after: retryDelay)
            }
        }
    }

    private func nextDelay(after delay: UInt64) -> UInt64 {
        guard delay < maximumRetryDelayNanoseconds else { return maximumRetryDelayNanoseconds }
        let doubled = delay.multipliedReportingOverflow(by: 2)
        guard !doubled.overflow else { return maximumRetryDelayNanoseconds }
        return min(doubled.partialValue, maximumRetryDelayNanoseconds)
    }
}

final class NotificationDriver {
    private var task: Task<Void, Never>?
    private var taskID = UUID()

    var isRunning: Bool { task != nil }

    func start(runner: NotificationSubscriptionRunner) {
        stop()
        let id = UUID()
        taskID = id
        task = Task { [weak self] in
            await runner.run()
            self?.clearCompletedTask(id: id)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        taskID = UUID()
    }

    deinit {
        task?.cancel()
    }

    private func clearCompletedTask(id: UUID) {
        guard taskID == id else { return }
        task = nil
    }
}

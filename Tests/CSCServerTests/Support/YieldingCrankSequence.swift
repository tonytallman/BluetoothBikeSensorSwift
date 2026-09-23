import CSCServer
import Foundation

final class YieldingCrankSequence: AsyncSequence, Sendable {
    typealias Element = CrankRevolution

    private let channel = YieldChannel()

    struct Iterator: AsyncIteratorProtocol, Sendable {
        let channel: YieldChannel

        func next() async throws -> CrankRevolution? {
            try await channel.next()
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(channel: channel)
    }

    func yield(_ revolution: CrankRevolution) async {
        await channel.send(revolution)
    }

    func iterationWasCancelled() async -> Bool {
        await channel.iterationWasCancelled
    }
}

actor YieldChannel {
    private var queue: [CrankRevolution] = []
    private var waiters: [CheckedContinuation<CrankRevolution?, Error>] = []
    private var finished = false
    private(set) var iterationWasCancelled = false

    func send(_ revolution: CrankRevolution) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: revolution)
            return
        }
        queue.append(revolution)
    }

    func next() async throws -> CrankRevolution? {
        if let next = queue.first {
            queue.removeFirst()
            return next
        }
        if finished {
            return nil
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CrankRevolution?, Error>) in
                waiters.append(continuation)
            }
        } onCancel: {
            Task {
                await self.cancelCurrentWait()
            }
        }
    }

    private func cancelCurrentWait() {
        iterationWasCancelled = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume(throwing: CancellationError())
        }
    }
}

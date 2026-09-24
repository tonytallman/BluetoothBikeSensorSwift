import CSCServer
import Foundation

final class YieldingWheelSequence: AsyncSequence, Sendable {
    typealias Element = WheelRevolution

    private let channel = YieldWheelChannel()

    struct Iterator: AsyncIteratorProtocol, Sendable {
        let channel: YieldWheelChannel

        func next() async throws -> WheelRevolution? {
            try await channel.next()
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(channel: channel)
    }

    func yield(_ revolution: WheelRevolution) async {
        await channel.send(revolution)
    }

    func iterationWasCancelled() async -> Bool {
        await channel.iterationWasCancelled
    }

    func waitUntilNextEntered(count: Int) async {
        await channel.waitUntilNextEntered(count: count)
    }
}

actor YieldWheelChannel {
    private var queue: [WheelRevolution] = []
    private var waiters: [CheckedContinuation<WheelRevolution?, Error>] = []
    private var finished = false
    private(set) var iterationWasCancelled = false
    private var entryCount = 0
    private var entryWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func send(_ revolution: WheelRevolution) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: revolution)
            return
        }
        queue.append(revolution)
    }

    func waitUntilNextEntered(count: Int) async {
        if entryCount >= count {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if entryCount >= count {
                continuation.resume()
                return
            }
            entryWaiters.append((count, continuation))
        }
    }

    func next() async throws -> WheelRevolution? {
        entryCount += 1
        resumeEntryWaiters(for: entryCount)

        if let next = queue.first {
            queue.removeFirst()
            return next
        }
        if finished {
            return nil
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WheelRevolution?, Error>) in
                waiters.append(continuation)
            }
        } onCancel: {
            Task {
                await self.cancelCurrentWait()
            }
        }
    }

    private func resumeEntryWaiters(for count: Int) {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, continuation) in entryWaiters {
            if count >= target {
                continuation.resume()
            } else {
                remaining.append((target, continuation))
            }
        }
        entryWaiters = remaining
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

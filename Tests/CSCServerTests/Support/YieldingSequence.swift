import CSCServer
import Foundation

final class YieldingSequence<Element: Sendable>: AsyncSequence, Sendable {
    private let channel = YieldChannel<Element>()

    struct Iterator: AsyncIteratorProtocol, Sendable {
        let channel: YieldChannel<Element>

        func next() async throws -> Element? {
            try await channel.next()
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(channel: channel)
    }

    func yield(_ element: Element) async {
        await channel.send(element)
    }

    func iterationWasCancelled() async -> Bool {
        await channel.iterationWasCancelled
    }

    /// Returns once `next()` has been entered at least `count` times.
    func waitUntilNextEntered(count: Int) async {
        await channel.waitUntilNextEntered(count: count)
    }
}

typealias YieldingWheelSequence = YieldingSequence<WheelRevolution>
typealias YieldingCrankSequence = YieldingSequence<CrankRevolution>

actor YieldChannel<Element: Sendable> {
    private var queue: [Element] = []
    private var waiters: [CheckedContinuation<Element?, Error>] = []
    private var finished = false
    private(set) var iterationWasCancelled = false
    private var entryCount = 0
    private var entryWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func send(_ element: Element) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: element)
            return
        }
        queue.append(element)
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

    func next() async throws -> Element? {
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
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Element?, Error>) in
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

func makeYieldingWheelAndCrankSequence() -> (
    sequence: YieldingWheelAndCrankSequence,
    yield: @Sendable (WheelAndCrankRevolution) async -> Void,
) {
    let sequence = YieldingWheelAndCrankSequence()
    return (sequence, { element in
        await sequence.yield(element)
    })
}

import CSCServer
import Foundation

final class ControlledCrankSequence: AsyncSequence, Sendable {
    typealias Element = CrankRevolution

    let samples: [CrankRevolution]
    private let counter = RequestCounter()

    init(samples: [CrankRevolution]) {
        self.samples = samples
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(counter: counter, samples: samples)
    }

    func waitForNextRequest(count: Int) async {
        await counter.waitForRequest(count: count)
    }

    struct Iterator: AsyncIteratorProtocol {
        let counter: RequestCounter
        let samples: [CrankRevolution]
        var index = 0

        mutating func next() async throws -> CrankRevolution? {
            guard index < samples.count else {
                return nil
            }
            await counter.recordRequest()
            let sample = samples[index]
            index += 1
            return sample
        }
    }
}

actor RequestCounter {
    private var requestCount = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var ended = false
    private var endWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilEnded() async {
        if ended {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            endWaiters.append(continuation)
        }
    }

    func recordEnd() {
        ended = true
        let pending = endWaiters
        endWaiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func waitForRequest(count: Int) async {
        if requestCount >= count {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append((count, continuation))
        }
    }

    func recordRequest() {
        requestCount += 1
        let current = requestCount
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, continuation) in waiters {
            if current >= target {
                continuation.resume()
            } else {
                remaining.append((target, continuation))
            }
        }
        waiters = remaining
    }
}

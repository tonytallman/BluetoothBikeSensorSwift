import CSCServer
import Foundation

final class ControlledWheelSequence: AsyncSequence, Sendable {
    typealias Element = WheelRevolution

    let samples: [WheelRevolution]
    private let counter = RequestCounter()
    private let gate = SampleGate()

    init(samples: [WheelRevolution]) {
        self.samples = samples
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(counter: counter, gate: gate, samples: samples)
    }

    func waitForNextRequest(count: Int) async {
        await counter.waitForRequest(count: count)
    }

    func releaseSample() async {
        await gate.release()
    }

    struct Iterator: AsyncIteratorProtocol {
        let counter: RequestCounter
        let gate: SampleGate
        let samples: [WheelRevolution]
        var index = 0

        mutating func next() async throws -> WheelRevolution? {
            guard index < samples.count else {
                return nil
            }
            await gate.waitUntilReleased()
            await counter.recordRequest()
            let sample = samples[index]
            index += 1
            return sample
        }
    }
}

actor SampleGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func waitUntilReleased() async {
        if released {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if released {
                continuation.resume()
                return
            }
            waiters.append(continuation)
        }
    }
}

import CSCServer
import Foundation

/// A source that never produces a sample and ends when its iterating task is cancelled.
struct NeverYieldingCrankSequence: AsyncSequence, Sendable {
    typealias Element = CrankRevolution

    struct Iterator: AsyncIteratorProtocol, Sendable {
        func next() async throws -> CrankRevolution? {
            try await parkUntilCancelled()
            return nil
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator()
    }
}

/// A source that never produces a sample and ends when its iterating task is cancelled.
struct NeverYieldingWheelSequence: AsyncSequence, Sendable {
    typealias Element = WheelRevolution

    struct Iterator: AsyncIteratorProtocol, Sendable {
        func next() async throws -> WheelRevolution? {
            try await parkUntilCancelled()
            return nil
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator()
    }
}

private func parkUntilCancelled() async throws {
    let parker = CancellationParker()
    try await withTaskCancellationHandler {
        try await parker.park()
    } onCancel: {
        Task {
            await parker.cancel()
        }
    }
}

private actor CancellationParker {
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false

    func park() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if cancelled || Task.isCancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
        }
    }

    func cancel() {
        cancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

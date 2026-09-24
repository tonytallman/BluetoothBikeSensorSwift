import CSCServer
import Foundation

actor ScriptedCumulativeDelegate: SetCumulativeWheelRevolutions {
    private(set) var recordedValues: [UInt32] = []
    private var shouldThrow = false
    private var parkArmed = false
    private var parkIgnoresCancellation = false
    private var parkedContinuation: CheckedContinuation<Void, Error>?
    private var recordedCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var cancellationRequested = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilRecordedCount(_ count: Int) async {
        if recordedValues.count >= count {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if recordedValues.count >= count {
                continuation.resume()
                return
            }
            recordedCountWaiters.append((count, continuation))
        }
    }

    func armParkForNextCall() {
        parkArmed = true
    }

    /// The next call parks until ``release()``; cancellation is only recorded.
    func armParkIgnoringCancellationForNextCall() {
        parkArmed = true
        parkIgnoresCancellation = true
    }

    func waitUntilCancellationRequested() async {
        if cancellationRequested {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if cancellationRequested {
                continuation.resume()
                return
            }
            cancellationWaiters.append(continuation)
        }
    }

    func setShouldThrow(_ value: Bool) {
        shouldThrow = value
    }

    func release() {
        guard let continuation = parkedContinuation else {
            return
        }
        parkedContinuation = nil
        continuation.resume()
    }

    func setCumulativeWheelRevolutions(_ cumulativeRevolutions: UInt32) async throws {
        recordedValues.append(cumulativeRevolutions)
        resumeRecordedCountWaiters(for: recordedValues.count)
        if shouldThrow {
            throw TestDelegateError.failure
        }

        guard parkArmed else {
            return
        }
        parkArmed = false
        let ignoresCancellation = parkIgnoresCancellation
        parkIgnoresCancellation = false

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                parkedContinuation = continuation
            }
        } onCancel: {
            Task {
                if ignoresCancellation {
                    await self.recordCancellationRequested()
                } else {
                    await self.cancelPark()
                }
            }
        }
    }

    private func recordCancellationRequested() {
        cancellationRequested = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func cancelPark() {
        guard let continuation = parkedContinuation else {
            return
        }
        parkedContinuation = nil
        continuation.resume(throwing: CancellationError())
    }

    private func resumeRecordedCountWaiters(for count: Int) {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, continuation) in recordedCountWaiters {
            if count >= target {
                continuation.resume()
            } else {
                remaining.append((target, continuation))
            }
        }
        recordedCountWaiters = remaining
    }
}

enum TestDelegateError: Error {
    case failure
}

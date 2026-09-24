import CSCServer
import Foundation
import os

final class ScriptedLocationDelegate: MultipleSensorLocationsDelegate, @unchecked Sendable {
    private struct State {
        var supported: [SensorLocationKind]
        let current: SensorLocationKind
        var updateCount = 0
        var recordedKinds: [SensorLocationKind] = []
        var shouldThrow = false
        var parkArmed = false
        var parkIgnoresCancellation = false
        var parkedContinuation: CheckedContinuation<Void, Error>?
        var updateCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        var cancellationRequested = false
        var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(supported: [SensorLocationKind], current: SensorLocationKind) {
        state = OSAllocatedUnfairLock(initialState: State(supported: supported, current: current))
    }

    var supported: [SensorLocationKind] {
        state.withLock { $0.supported }
    }

    var current: SensorLocationKind {
        state.withLock { $0.current }
    }

    var recordedUpdateKinds: [SensorLocationKind] {
        state.withLock { $0.recordedKinds }
    }

    var updateInvocationCount: Int {
        state.withLock { $0.updateCount }
    }

    func setSupported(_ locations: [SensorLocationKind]) {
        state.withLock { $0.supported = locations }
    }

    func waitUntilUpdateCount(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.withLock { locked in
                if locked.updateCount >= count {
                    continuation.resume()
                    return
                }
                locked.updateCountWaiters.append((count, continuation))
            }
        }
    }

    func armParkForNextCall() {
        state.withLock { $0.parkArmed = true }
    }

    /// The next call parks until ``release()``; cancellation is only recorded.
    func armParkIgnoringCancellationForNextCall() {
        state.withLock { locked in
            locked.parkArmed = true
            locked.parkIgnoresCancellation = true
        }
    }

    func waitUntilCancellationRequested() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.withLock { locked in
                if locked.cancellationRequested {
                    continuation.resume()
                    return
                }
                locked.cancellationWaiters.append(continuation)
            }
        }
    }

    func setShouldThrow(_ value: Bool) {
        state.withLock { $0.shouldThrow = value }
    }

    func release() {
        let continuation = state.withLock { locked -> CheckedContinuation<Void, Error>? in
            guard let continuation = locked.parkedContinuation else {
                return nil
            }
            locked.parkedContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func update(_ location: SensorLocationKind) async throws {
        let (willPark, ignoresCancellation) = state.withLock { locked -> (Bool, Bool) in
            if locked.shouldThrow {
                return (false, false)
            }
            if locked.parkArmed {
                locked.parkArmed = false
                let ignores = locked.parkIgnoresCancellation
                locked.parkIgnoresCancellation = false
                return (true, ignores)
            }
            return (false, false)
        }

        if willPark {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    state.withLock { locked in
                        locked.recordedKinds.append(location)
                        locked.updateCount += 1
                        locked.parkedContinuation = continuation
                        resumeUpdateCountWaiters(locked: &locked, for: locked.updateCount)
                    }
                }
            } onCancel: {
                if ignoresCancellation {
                    self.recordCancellationRequested()
                } else {
                    self.cancelPark()
                }
            }
            return
        }

        let shouldThrow = state.withLock { locked -> Bool in
            locked.recordedKinds.append(location)
            locked.updateCount += 1
            let throwNow = locked.shouldThrow
            resumeUpdateCountWaiters(locked: &locked, for: locked.updateCount)
            return throwNow
        }

        if shouldThrow {
            throw TestDelegateError.failure
        }
    }

    private func recordCancellationRequested() {
        let waiters = state.withLock { locked -> [CheckedContinuation<Void, Never>] in
            locked.cancellationRequested = true
            let waiters = locked.cancellationWaiters
            locked.cancellationWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func cancelPark() {
        let continuation = state.withLock { locked -> CheckedContinuation<Void, Error>? in
            guard let continuation = locked.parkedContinuation else {
                return nil
            }
            locked.parkedContinuation = nil
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func resumeUpdateCountWaiters(locked: inout State, for count: Int) {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, continuation) in locked.updateCountWaiters {
            if count >= target {
                continuation.resume()
            } else {
                remaining.append((target, continuation))
            }
        }
        locked.updateCountWaiters = remaining
    }
}

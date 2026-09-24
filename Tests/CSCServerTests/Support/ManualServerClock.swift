import CSCServer
import Foundation

/// Virtual-time ``ServerClock``. Sleepers resume only when ``advance(by:)`` reaches their deadline.
actor ManualServerClock: ServerClock {
    private struct Sleeper {
        let id: UUID
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private var now: Duration = .zero
    private(set) var requestedDurations: [Duration] = []
    private var sleepers: [Sleeper] = []
    private var sleeperCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(for duration: Duration) async throws {
        requestedDurations.append(duration)
        let id = UUID()
        let deadline = now + duration
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if deadline <= now {
                    continuation.resume()
                    return
                }
                sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                resumeSleeperCountWaiters()
            }
        } onCancel: {
            Task {
                await self.cancelSleeper(id)
            }
        }
    }

    func advance(by duration: Duration) {
        now += duration
        let due = sleepers.filter { $0.deadline <= now }
        sleepers.removeAll { $0.deadline <= now }
        for sleeper in due {
            sleeper.continuation.resume()
        }
        resumeSleeperCountWaiters()
    }

    var sleeperCount: Int {
        sleepers.count
    }

    /// Returns once exactly `count` sleepers are parked.
    func waitUntilSleeperCount(_ count: Int) async {
        if sleepers.count == count {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if sleepers.count == count {
                continuation.resume()
                return
            }
            sleeperCountWaiters.append((count, continuation))
        }
    }

    private func cancelSleeper(_ id: UUID) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
            return
        }
        let sleeper = sleepers.remove(at: index)
        sleeper.continuation.resume(throwing: CancellationError())
        resumeSleeperCountWaiters()
    }

    private func resumeSleeperCountWaiters() {
        let count = sleepers.count
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, continuation) in sleeperCountWaiters {
            if count == target {
                continuation.resume()
            } else {
                remaining.append((target, continuation))
            }
        }
        sleeperCountWaiters = remaining
    }
}

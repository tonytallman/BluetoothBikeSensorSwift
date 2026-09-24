import Foundation

/// Slot for the one `Server` that may be starting, running, or stopping at a time.
package final class LiveServerRegistry: @unchecked Sendable {
    package static let shared = LiveServerRegistry()

    private let lock = NSLock()
    private var token: UUID?
    private var vacancyWaiters: [CheckedContinuation<Void, Never>] = []

    package init() {}

    /// Returns a token for the slot, or `nil` when it is occupied.
    package func claim() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard token == nil else {
            return nil
        }
        let claimed = UUID()
        token = claimed
        return claimed
    }

    /// Vacates the slot when `token` holds it. Does nothing otherwise.
    package func release(_ token: UUID) {
        lock.lock()
        guard self.token == token else {
            lock.unlock()
            return
        }
        self.token = nil
        let waiters = vacancyWaiters
        vacancyWaiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    package var isOccupied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return token != nil
    }

    package func waitUntilVacant() async {
        if !isOccupied {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if token == nil {
                lock.unlock()
                continuation.resume()
                return
            }
            vacancyWaiters.append(continuation)
            lock.unlock()
        }
    }
}

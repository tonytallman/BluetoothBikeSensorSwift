import Foundation
@testable import SampleServerApp

final class ManualTicker: SimulationTicker, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Void>.Continuation?
    private var pendingTicks = 0

    func ticks() -> AsyncStream<Void> {
        AsyncStream { continuation in
            lock.lock()
            self.continuation = continuation
            let pending = pendingTicks
            pendingTicks = 0
            lock.unlock()
            for _ in 0 ..< pending {
                continuation.yield(())
            }
        }
    }

    func tick() {
        lock.lock()
        if let continuation {
            continuation.yield(())
        } else {
            pendingTicks &+= 1
        }
        lock.unlock()
    }

    func finish() {
        lock.lock()
        continuation?.finish()
        continuation = nil
        pendingTicks = 0
        lock.unlock()
    }
}

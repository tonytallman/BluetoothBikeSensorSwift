import Foundation
@testable import SampleServerApp

final class ManualTicker: SimulationTicker, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Void>.Continuation?

    func ticks() -> AsyncStream<Void> {
        AsyncStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    func tick() {
        lock.lock()
        continuation?.yield(())
        lock.unlock()
    }

    func finish() {
        lock.lock()
        continuation?.finish()
        continuation = nil
        lock.unlock()
    }
}

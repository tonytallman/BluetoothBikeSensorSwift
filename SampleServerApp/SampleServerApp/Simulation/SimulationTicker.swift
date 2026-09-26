import Foundation

protocol SimulationTicker: Sendable {
    func ticks() -> AsyncStream<Void>
}

struct SleepingTicker: SimulationTicker {
    let interval: Duration

    func ticks() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: interval)
                    } catch {
                        break
                    }
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

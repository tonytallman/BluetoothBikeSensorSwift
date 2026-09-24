import Foundation

struct ActiveTimeline: Equatable {
    private(set) var accumulatedActive: Duration = .zero
    private var anchor: Duration = .zero
    private var pausedAt: Duration?
    private var isPaused = false

    mutating func pause(at elapsed: Duration) {
        guard !isPaused else { return }
        accumulatedActive += elapsed - anchor
        pausedAt = elapsed
        isPaused = true
    }

    mutating func resume(at elapsed: Duration) {
        guard isPaused else { return }
        anchor = elapsed
        pausedAt = nil
        isPaused = false
    }

    func activeElapsed(at elapsed: Duration) -> Duration {
        if isPaused, let pausedAt {
            return accumulatedActive + (pausedAt - anchor)
        }
        return accumulatedActive + (elapsed - anchor)
    }
}

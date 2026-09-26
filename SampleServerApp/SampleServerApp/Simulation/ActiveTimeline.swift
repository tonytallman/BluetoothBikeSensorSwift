import Foundation

struct ActiveTimeline: Equatable {
    private(set) var accumulatedActive: Duration = .zero
    private var anchor: Duration = .zero
    private var isPaused = false

    mutating func pause(at elapsed: Duration) {
        guard !isPaused else { return }
        accumulatedActive += elapsed - anchor
        isPaused = true
    }

    mutating func resume(at elapsed: Duration) {
        guard isPaused else { return }
        anchor = elapsed
        isPaused = false
    }

    func activeElapsed(at elapsed: Duration) -> Duration {
        if isPaused {
            return accumulatedActive
        }
        return accumulatedActive + (elapsed - anchor)
    }
}

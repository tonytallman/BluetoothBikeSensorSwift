import Foundation

protocol MonotonicTimeSource: Sendable {
    var elapsed: Duration { get }
}

struct ContinuousTimeSource: MonotonicTimeSource {
    private let start = ContinuousClock.now

    var elapsed: Duration {
        start.duration(to: ContinuousClock.now)
    }
}

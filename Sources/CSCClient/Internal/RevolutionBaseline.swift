import Foundation

package struct RevolutionBaseline<Count: FixedWidthInteger & UnsignedInteger & Sendable> {
    private var previousRevolutions: Count?
    private var previousEventTime: UInt16?

    package init() {}

    package mutating func delta(revolutions: Count, eventTime: UInt16) -> (revolutions: Count, seconds: Double)? {
        defer {
            previousRevolutions = revolutions
            previousEventTime = eventTime
        }

        guard let previousRevolutions, let previousEventTime else {
            return nil
        }

        let deltaRevolutions = revolutions &- previousRevolutions
        let seconds = Double(eventTime &- previousEventTime) / 1024.0
        guard seconds != 0 else {
            return nil
        }

        return (deltaRevolutions, seconds)
    }

    mutating func reset() {
        previousRevolutions = nil
        previousEventTime = nil
    }
}

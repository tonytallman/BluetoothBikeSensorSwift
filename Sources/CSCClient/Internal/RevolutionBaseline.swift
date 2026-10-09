import Foundation

/// Previous CSC cumulative count and last-event time for one measurement half.
///
/// The first call, and any call after ``reset()``, stores the sample and returns `nil`.
/// Later calls return the unsigned delta. Event time is `UInt16` at 1/1024 second and wraps
/// every 64 seconds; both counters use wrapping subtraction, so a silent gap longer
/// than that looks like a short interval. A zero event-time delta returns `nil` and still
/// stores the new sample, so the next interval starts at the duplicate instead of spanning it.
///
/// ``WheelRevolutions`` and ``CrankRevolutions`` apply their speed and cadence caps after this
/// returns. Those caps can drop the sample, but this value has already moved.
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

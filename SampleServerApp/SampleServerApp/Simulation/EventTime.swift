import Foundation

enum EventTime {
    /// CSC last-event time: 1/1024 s ticks, wrapping every 64 s. `elapsed` is never negative.
    static func wireValue(for elapsed: Duration) -> UInt16 {
        let (seconds, attoseconds) = elapsed.components
        let wholeTicks = (seconds % 64) * 1024
        let fractionTicks = (attoseconds + 488_281_250_000_000) / 976_562_500_000_000
        return UInt16(truncatingIfNeeded: wholeTicks + fractionTicks)
    }
}

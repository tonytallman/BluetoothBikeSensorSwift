import Foundation

enum ClientFormula {
    static func speedKilometersPerHour(
        previousCumulative: UInt32,
        previousEventTime: UInt16,
        currentCumulative: UInt32,
        currentEventTime: UInt16,
        circumferenceMeters: Double,
    ) -> Double? {
        let deltaRev = currentCumulative &- previousCumulative
        let deltaTicks = currentEventTime &- previousEventTime
        if deltaTicks == 0 {
            return nil
        }
        let deltaSeconds = Double(deltaTicks) / 1024.0
        let metersPerSecond = Double(deltaRev) * circumferenceMeters / deltaSeconds
        return metersPerSecond * 3.6
    }

    static func cadenceRPM(
        previousCumulative: UInt16,
        previousEventTime: UInt16,
        currentCumulative: UInt16,
        currentEventTime: UInt16,
    ) -> Double? {
        let deltaRev = currentCumulative &- previousCumulative
        let deltaTicks = currentEventTime &- previousEventTime
        if deltaTicks == 0 {
            return nil
        }
        let deltaSeconds = Double(deltaTicks) / 1024.0
        return Double(deltaRev) * 60.0 / deltaSeconds
    }
}

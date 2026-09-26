import Foundation

enum RevolutionPeriod {
    static func wheelPeriod(
        speedKilometersPerHour: Double,
        circumferenceMeters: Double,
    ) -> Duration {
        let metersPerSecond = speedKilometersPerHour / 3.6
        guard metersPerSecond > 0 else {
            return .seconds(1)
        }
        let seconds = circumferenceMeters / metersPerSecond
        return .seconds(seconds)
    }

    static func crankPeriod(revolutionsPerMinute: Double) -> Duration {
        guard revolutionsPerMinute > 0 else {
            return .seconds(1)
        }
        let seconds = 60.0 / revolutionsPerMinute
        return .seconds(seconds)
    }
}

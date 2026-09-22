package import CSCWire
import Foundation

package struct CSCMeasurementState: Sendable, Equatable {
    package var previousWheelRevolutions: UInt32?
    package var previousWheelEventTime: UInt16?
    package var previousCrankRevolutions: UInt16?
    package var previousCrankEventTime: UInt16?

    package init(
        previousWheelRevolutions: UInt32? = nil,
        previousWheelEventTime: UInt16? = nil,
        previousCrankRevolutions: UInt16? = nil,
        previousCrankEventTime: UInt16? = nil,
    ) {
        self.previousWheelRevolutions = previousWheelRevolutions
        self.previousWheelEventTime = previousWheelEventTime
        self.previousCrankRevolutions = previousCrankRevolutions
        self.previousCrankEventTime = previousCrankEventTime
    }
}

package struct CSCWheelDelta: Sendable, Equatable {
    package let deltaRevolutions: UInt32
    package let deltaTimeSeconds: Double
}

package struct CSCCrankDelta: Sendable, Equatable {
    package let deltaRevolutions: UInt16
    package let deltaTimeSeconds: Double
}

package enum CSCDeltaLimits {
    package static let maxWheelSpeedMetersPerSecond: Double = 50
    package static let maxCadenceRevolutionsPerMinute: Double = 300
}

package enum CSCMeasurementParser {
    /// Only state-advancing wheel entry point.
    package static func wheelDelta(
        from sample: CSCMeasurement,
        previous: inout CSCMeasurementState,
        circumferenceMeters: Double,
    ) -> CSCWheelDelta? {
        guard let revolutions = sample.cumulativeWheelRevolutions,
              let eventTime = sample.lastWheelEventTime
        else {
            return nil
        }

        guard let previousRevolutions = previous.previousWheelRevolutions,
              let previousEventTime = previous.previousWheelEventTime
        else {
            previous.previousWheelRevolutions = revolutions
            previous.previousWheelEventTime = eventTime
            return nil
        }

        let deltaRevolutions = revolutions &- previousRevolutions
        let deltaTimeSeconds = Double(eventTime &- previousEventTime) / 1024.0

        previous.previousWheelRevolutions = revolutions
        previous.previousWheelEventTime = eventTime

        guard deltaTimeSeconds > 0 else {
            return nil
        }

        let impliedSpeed = (Double(deltaRevolutions) * circumferenceMeters) / deltaTimeSeconds
        if impliedSpeed > CSCDeltaLimits.maxWheelSpeedMetersPerSecond {
            return nil
        }

        return CSCWheelDelta(
            deltaRevolutions: deltaRevolutions,
            deltaTimeSeconds: deltaTimeSeconds,
        )
    }

    /// Only state-advancing crank entry point.
    package static func crankDelta(
        from sample: CSCMeasurement,
        previous: inout CSCMeasurementState,
    ) -> CSCCrankDelta? {
        guard let revolutions = sample.cumulativeCrankRevolutions,
              let eventTime = sample.lastCrankEventTime
        else {
            return nil
        }

        guard let previousRevolutions = previous.previousCrankRevolutions,
              let previousEventTime = previous.previousCrankEventTime
        else {
            previous.previousCrankRevolutions = revolutions
            previous.previousCrankEventTime = eventTime
            return nil
        }

        let deltaRevolutions = revolutions &- previousRevolutions
        let deltaTimeSeconds = Double(eventTime &- previousEventTime) / 1024.0

        previous.previousCrankRevolutions = revolutions
        previous.previousCrankEventTime = eventTime

        guard deltaTimeSeconds > 0 else {
            return nil
        }

        let impliedCadence = (Double(deltaRevolutions) / deltaTimeSeconds) * 60.0
        if impliedCadence > CSCDeltaLimits.maxCadenceRevolutionsPerMinute {
            return nil
        }

        return CSCCrankDelta(
            deltaRevolutions: deltaRevolutions,
            deltaTimeSeconds: deltaTimeSeconds,
        )
    }

    /// Pure mapping. Call only with a delta that already passed Δt > 0 and the implausible-delta guard.
    package static func speed(
        from delta: CSCWheelDelta,
        circumferenceMeters: Double,
    ) -> Speed {
        let metersPerSecond = (Double(delta.deltaRevolutions) * circumferenceMeters) / delta.deltaTimeSeconds
        return Measurement(value: metersPerSecond, unit: UnitSpeed.metersPerSecond)
    }

    /// Pure mapping. Call only with a delta that already passed Δt > 0 and the implausible-delta guard.
    package static func cadence(from delta: CSCCrankDelta) -> Cadence {
        let revolutionsPerMinute = (Double(delta.deltaRevolutions) / delta.deltaTimeSeconds) * 60.0
        return Measurement(value: revolutionsPerMinute, unit: .revolutionsPerMinute)
    }
}

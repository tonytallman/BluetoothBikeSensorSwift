import CSCWire
import Foundation

enum CSCMeasurementFixtures {
    static func wheelMeasurement(revolutions: UInt32, eventTime: UInt16) -> Data {
        CSCMeasurement(
            cumulativeWheelRevolutions: revolutions,
            lastWheelEventTime: eventTime,
        ).encode()!
    }

    static func crankMeasurement(revolutions: UInt16, eventTime: UInt16) -> Data {
        CSCMeasurement(
            cumulativeCrankRevolutions: revolutions,
            lastCrankEventTime: eventTime,
        ).encode()!
    }

    static func combinedMeasurement(
        wheelRevolutions: UInt32,
        wheelEventTime: UInt16,
        crankRevolutions: UInt16,
        crankEventTime: UInt16,
    ) -> Data {
        CSCMeasurement(
            cumulativeWheelRevolutions: wheelRevolutions,
            lastWheelEventTime: wheelEventTime,
            cumulativeCrankRevolutions: crankRevolutions,
            lastCrankEventTime: crankEventTime,
        ).encode()!
    }
}


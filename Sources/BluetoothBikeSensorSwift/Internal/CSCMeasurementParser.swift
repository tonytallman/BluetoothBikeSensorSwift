import Foundation

package struct CSCMeasurementSample: Sendable, Equatable {
    package let cumulativeWheelRevolutions: UInt32?
    package let lastWheelEventTime: UInt16?
    package let cumulativeCrankRevolutions: UInt16?
    package let lastCrankEventTime: UInt16?
}

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

package enum CSCMeasurementParser {
    package static func parse(_ data: Data) -> CSCMeasurementSample? {
        guard !data.isEmpty else {
            return nil
        }

        let flags = data[0]
        var offset = 1
        var cumulativeWheelRevolutions: UInt32?
        var lastWheelEventTime: UInt16?
        var cumulativeCrankRevolutions: UInt16?
        var lastCrankEventTime: UInt16?

        if flags & 0x01 != 0 {
            guard data.count >= offset + 6 else {
                return nil
            }
            cumulativeWheelRevolutions = readUInt32LE(data, offset)
            offset += 4
            lastWheelEventTime = readUInt16LE(data, offset)
            offset += 2
        }

        if flags & 0x02 != 0 {
            guard data.count >= offset + 4 else {
                return nil
            }
            cumulativeCrankRevolutions = readUInt16LE(data, offset)
            offset += 2
            lastCrankEventTime = readUInt16LE(data, offset)
        }

        return CSCMeasurementSample(
            cumulativeWheelRevolutions: cumulativeWheelRevolutions,
            lastWheelEventTime: lastWheelEventTime,
            cumulativeCrankRevolutions: cumulativeCrankRevolutions,
            lastCrankEventTime: lastCrankEventTime,
        )
    }

    package static func speed(
        from sample: CSCMeasurementSample,
        previous: inout CSCMeasurementState,
        circumferenceMeters: Double,
    ) -> Speed? {
        guard let revolutions = sample.cumulativeWheelRevolutions,
              let eventTime = sample.lastWheelEventTime,
              let previousRevolutions = previous.previousWheelRevolutions,
              let previousEventTime = previous.previousWheelEventTime
        else {
            previous.previousWheelRevolutions = sample.cumulativeWheelRevolutions
            previous.previousWheelEventTime = sample.lastWheelEventTime
            return nil
        }

        let deltaRevolutions = Double(revolutions &- previousRevolutions)
        let deltaTimeSeconds = Double(eventTime &- previousEventTime) / 1024.0

        previous.previousWheelRevolutions = revolutions
        previous.previousWheelEventTime = eventTime

        guard deltaTimeSeconds > 0 else {
            return nil
        }

        let metersPerSecond = (deltaRevolutions * circumferenceMeters) / deltaTimeSeconds
        return Measurement(value: metersPerSecond, unit: UnitSpeed.metersPerSecond)
    }

    package static func cadence(
        from sample: CSCMeasurementSample,
        previous: inout CSCMeasurementState,
    ) -> Cadence? {
        guard let revolutions = sample.cumulativeCrankRevolutions,
              let eventTime = sample.lastCrankEventTime,
              let previousRevolutions = previous.previousCrankRevolutions,
              let previousEventTime = previous.previousCrankEventTime
        else {
            previous.previousCrankRevolutions = sample.cumulativeCrankRevolutions
            previous.previousCrankEventTime = sample.lastCrankEventTime
            return nil
        }

        let deltaRevolutions = Double(revolutions &- previousRevolutions)
        let deltaTimeSeconds = Double(eventTime &- previousEventTime) / 1024.0

        previous.previousCrankRevolutions = revolutions
        previous.previousCrankEventTime = eventTime

        guard deltaTimeSeconds > 0 else {
            return nil
        }

        let revolutionsPerMinute = (deltaRevolutions / deltaTimeSeconds) * 60.0
        return Measurement(value: revolutionsPerMinute, unit: .revolutionsPerMinute)
    }

    private static func readUInt16LE(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

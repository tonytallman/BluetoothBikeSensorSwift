import Foundation

struct CSCMeasurementSample: Sendable, Equatable {
    let cumulativeWheelRevolutions: UInt32?
    let lastWheelEventTime: UInt16?
    let cumulativeCrankRevolutions: UInt16?
    let lastCrankEventTime: UInt16?
}

struct CSCMeasurementState: Sendable, Equatable {
    var previousWheelRevolutions: UInt32?
    var previousWheelEventTime: UInt16?
    var previousCrankRevolutions: UInt16?
    var previousCrankEventTime: UInt16?
}

enum CSCMeasurementParser {
    static func parse(_ data: Data) -> CSCMeasurementSample? {
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

    static func speed(
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

    static func cadence(
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

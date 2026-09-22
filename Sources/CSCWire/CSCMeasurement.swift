import Foundation

package struct CSCMeasurement: Sendable, Equatable {
    package let cumulativeWheelRevolutions: UInt32?
    package let lastWheelEventTime: UInt16?
    package let cumulativeCrankRevolutions: UInt16?
    package let lastCrankEventTime: UInt16?

    package init(
        cumulativeWheelRevolutions: UInt32? = nil,
        lastWheelEventTime: UInt16? = nil,
        cumulativeCrankRevolutions: UInt16? = nil,
        lastCrankEventTime: UInt16? = nil,
    ) {
        self.cumulativeWheelRevolutions = cumulativeWheelRevolutions
        self.lastWheelEventTime = lastWheelEventTime
        self.cumulativeCrankRevolutions = cumulativeCrankRevolutions
        self.lastCrankEventTime = lastCrankEventTime
    }

    package static func decode(_ data: Data) -> CSCMeasurement? {
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
            cumulativeWheelRevolutions = LittleEndian.readUInt32(data, offset)
            offset += 4
            lastWheelEventTime = LittleEndian.readUInt16(data, offset)
            offset += 2
        }

        if flags & 0x02 != 0 {
            guard data.count >= offset + 4 else {
                return nil
            }
            cumulativeCrankRevolutions = LittleEndian.readUInt16(data, offset)
            offset += 2
            lastCrankEventTime = LittleEndian.readUInt16(data, offset)
        }

        return CSCMeasurement(
            cumulativeWheelRevolutions: cumulativeWheelRevolutions,
            lastWheelEventTime: lastWheelEventTime,
            cumulativeCrankRevolutions: cumulativeCrankRevolutions,
            lastCrankEventTime: lastCrankEventTime,
        )
    }

    package func encode() -> Data? {
        var flags: UInt8 = 0
        var payload = Data()

        if let cumulativeWheelRevolutions,
           let lastWheelEventTime
        {
            flags |= 0x01
            payload.append(contentsOf: LittleEndian.writeUInt32(cumulativeWheelRevolutions))
            payload.append(contentsOf: LittleEndian.writeUInt16(lastWheelEventTime))
        }

        if let cumulativeCrankRevolutions,
           let lastCrankEventTime
        {
            flags |= 0x02
            payload.append(contentsOf: LittleEndian.writeUInt16(cumulativeCrankRevolutions))
            payload.append(contentsOf: LittleEndian.writeUInt16(lastCrankEventTime))
        }

        guard !payload.isEmpty else {
            return nil
        }

        return Data([flags]) + payload
    }
}

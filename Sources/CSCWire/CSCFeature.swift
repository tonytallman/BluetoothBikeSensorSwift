import Foundation

package struct CSCFeature: OptionSet, Sendable, Hashable {
    package let rawValue: UInt16

    package init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    package static let wheelRevolutionData = CSCFeature(rawValue: 1 << 0)
    package static let crankRevolutionData = CSCFeature(rawValue: 1 << 1)
    package static let multipleSensorLocations = CSCFeature(rawValue: 1 << 2)

    package static func decode(_ data: Data) -> CSCFeature? {
        guard data.count >= 2 else {
            return nil
        }

        let flags = UInt16(data[0]) | (UInt16(data[1]) << 8)
        return CSCFeature(rawValue: flags)
    }

    package func encode() -> Data {
        Data(LittleEndian.writeUInt16(rawValue))
    }
}

import Foundation

package enum CSCFeatureParser {
    package struct Capabilities: Sendable, Equatable {
        package let hasSpeed: Bool
        package let hasCadence: Bool
    }

    package static func parse(_ data: Data) -> Capabilities? {
        guard data.count >= 2 else {
            return nil
        }

        let flags = UInt16(data[0]) | (UInt16(data[1]) << 8)
        return Capabilities(
            hasSpeed: flags & 0x01 != 0,
            hasCadence: flags & 0x02 != 0,
        )
    }
}

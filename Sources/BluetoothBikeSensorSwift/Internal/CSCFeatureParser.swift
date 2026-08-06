import Foundation

enum CSCFeatureParser {
    struct Capabilities: Sendable, Equatable {
        let hasSpeed: Bool
        let hasCadence: Bool
    }

    static func parse(_ data: Data) -> Capabilities? {
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

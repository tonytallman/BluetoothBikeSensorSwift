import Foundation

struct CBUUIDBridge: Sendable {
    let uuid: UUID

    init(uuid: UUID) {
        self.uuid = uuid
    }
}

#if canImport(CoreBluetooth)
import CoreBluetooth

extension CBUUIDBridge {
    var cbUUID: CBUUID {
        CBUUID(nsuuid: uuid)
    }

    /// Reconstructs a full 128-bit `UUID` from a CoreBluetooth `CBUUID`, which prints short
    /// UUIDs as just their 16-bit or 32-bit assigned-number hex. Short forms are expanded against
    /// the Bluetooth Base UUID (`0000xxxx-0000-1000-8000-00805F9B34FB`); anything else is already
    /// a full UUID string.
    static func foundationUUID(from cbUUID: CBUUID) -> UUID? {
        let uuidString = cbUUID.uuidString
        if uuidString.count == 4 {
            return UUID(uuidString: "0000\(uuidString)-0000-1000-8000-00805F9B34FB")
        }
        if uuidString.count == 8 {
            return UUID(uuidString: "\(uuidString)-0000-1000-8000-00805F9B34FB")
        }
        return UUID(uuidString: uuidString)
    }
}
#endif

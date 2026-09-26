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

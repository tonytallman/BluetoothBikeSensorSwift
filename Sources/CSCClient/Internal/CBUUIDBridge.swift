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
}
#endif

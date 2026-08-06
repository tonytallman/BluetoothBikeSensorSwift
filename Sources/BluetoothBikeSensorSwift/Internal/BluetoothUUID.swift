import Foundation

enum BluetoothUUID {
    static func standard(_ shortUUID: String) -> UUID {
        CBUUIDBridge(shortString: shortUUID).uuid
    }
}

struct CBUUIDBridge: Sendable {
    let uuid: UUID

    init(uuid: UUID) {
        self.uuid = uuid
    }

    init(shortString: String) {
        uuid = UUID(uuidString: "0000\(shortString)-0000-1000-8000-00805F9B34FB")!
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

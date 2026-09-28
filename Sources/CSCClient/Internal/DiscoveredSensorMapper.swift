internal import CSCWire
import Foundation

enum DiscoveredSensorMapper {
    static func map(
        _ event: DiscoveredPeripheral,
        central: any BluetoothCentral,
        timeouts: Timeouts,
    ) -> DiscoveredSensor? {
        guard event.serviceUUIDs.contains(CSCS.serviceUUID) else {
            return nil
        }

        return DiscoveredSensor(
            id: event.id,
            name: event.name,
            manufacturer: ManufacturerLookup.manufacturerName(from: event.manufacturerData),
            central: central,
            timeouts: timeouts,
        )
    }
}

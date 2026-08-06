import Foundation

enum DiscoveredSensorMapper {
    static func map(_ event: DiscoveredPeripheralEvent, central: any BluetoothCentral) -> DiscoveredSensor? {
        guard event.serviceUUIDs.contains(CSCS.serviceUUID) else {
            return nil
        }

        return DiscoveredSensor(
            id: event.id,
            name: event.name,
            manufacturer: ManufacturerLookup.manufacturerName(from: event.manufacturerData),
            hasSpeed: true,
            hasCadence: true,
            central: central,
        )
    }
}

import Foundation

enum CSCConnectionSetup {
    static func prepare(
        central: any BluetoothCentral,
        id: UUID,
        fallbackHasSpeed: Bool,
        fallbackHasCadence: Bool,
    ) async throws -> (hasSpeed: Bool, hasCadence: Bool) {
        try await central.discoverCharacteristics(
            id: id,
            serviceUUID: CSCS.serviceUUID,
            characteristicUUIDs: [CSCS.measurementUUID, CSCS.featureUUID],
        )

        var hasSpeed = fallbackHasSpeed
        var hasCadence = fallbackHasCadence

        do {
            let featureData = try await central.readValue(
                id: id,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.featureUUID,
            )
            if let capabilities = CSCFeatureParser.parse(featureData) {
                hasSpeed = capabilities.hasSpeed
                hasCadence = capabilities.hasCadence
            }
        } catch {
            // Keep discovery flags when Feature is missing or unreadable.
        }

        try await central.setNotifyValue(
            id: id,
            serviceUUID: CSCS.serviceUUID,
            characteristicUUID: CSCS.measurementUUID,
            enabled: true,
        )

        return (hasSpeed, hasCadence)
    }
}

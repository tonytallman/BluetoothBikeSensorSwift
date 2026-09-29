import CSCClient
import CSCWire
import Foundation

enum FakeCharacteristicSets {
    static let allCSCCharacteristicUUIDs = [
        CSCS.measurementUUID,
        CSCS.featureUUID,
        CSCS.sensorLocationUUID,
        CSCS.controlPointUUID,
    ]

    static func crankOnlyCharacteristics() -> [UUID] {
        [
            CSCS.measurementUUID,
            CSCS.featureUUID,
        ]
    }

    static func wheelAndControlPointCharacteristics() -> [UUID] {
        [
            CSCS.measurementUUID,
            CSCS.featureUUID,
            CSCS.controlPointUUID,
        ]
    }
}

enum CSCClientTestSupport {
    static func sensor(
        id: UUID = UUID(),
        name: String = "Test Sensor",
        central: FakeBluetoothCentral,
        timeouts: Timeouts = Timeouts(),
    ) -> DiscoveredSensor {
        DiscoveredSensor(
            id: id,
            name: name,
            manufacturer: nil,
            central: central,
            timeouts: timeouts,
        )
    }

    static func emitMeasurement(
        _ measurement: CSCMeasurement,
        from fake: FakeBluetoothCentral,
        peripheralID: UUID,
    ) async {
        guard let payload = measurement.encode() else {
            return
        }
        await fake.emit(
            .valueUpdated(
                peripheralID: peripheralID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
                value: payload,
            ),
        )
    }

    static func controlPointWrites(on fake: FakeBluetoothCentral) async -> Int {
        await fake.controlPointWriteCount()
    }

    static func waitForControlPointWrite(
        on fake: FakeBluetoothCentral,
        after baseline: Int,
    ) async {
        await fake.waitForControlPointWriteCount(above: baseline)
    }

    static func hasControlPointNotifyEnabled(
        in calls: [FakeBluetoothCentral.RecordedCall],
        sensorID: UUID,
    ) -> Bool {
        calls.contains { call in
            guard case let .setNotifyValue(
                id,
                serviceUUID,
                characteristicUUID,
                enabled,
            ) = call else {
                return false
            }
            return id == sensorID
                && serviceUUID == CSCS.serviceUUID
                && characteristicUUID == CSCS.controlPointUUID
                && enabled
        }
    }

    static func hasMeasurementNotifyEnabled(
        in calls: [FakeBluetoothCentral.RecordedCall],
        sensorID: UUID,
    ) -> Bool {
        calls.contains { call in
            guard case let .setNotifyValue(
                id,
                serviceUUID,
                characteristicUUID,
                enabled,
            ) = call else {
                return false
            }
            return id == sensorID
                && serviceUUID == CSCS.serviceUUID
                && characteristicUUID == CSCS.measurementUUID
                && enabled
        }
    }
}

import CSCClient
import CSCWire
import Foundation
import Testing

enum ConnectedSensorTestHelpers {
    static let allCSCCharacteristicUUIDs = [
        CSCS.measurementUUID,
        CSCS.featureUUID,
        CSCS.sensorLocationUUID,
        CSCS.controlPointUUID,
    ]

    static func wheel(from connected: ConnectedSensor) -> WheelRevolutions? {
        switch connected.revolutions {
        case let .wheel(wheel):
            return wheel
        case let .wheelAndCrank(wheel, _):
            return wheel
        case .crank:
            return nil
        }
    }

    static func crank(from connected: ConnectedSensor) -> CrankRevolutions? {
        switch connected.revolutions {
        case let .crank(crank):
            return crank
        case let .wheelAndCrank(_, crank):
            return crank
        case .wheel:
            return nil
        }
    }

    static func wheelAndControlPointCharacteristics() -> [UUID] {
        [
            CSCS.measurementUUID,
            CSCS.featureUUID,
            CSCS.controlPointUUID,
        ]
    }

    static func crankOnlyCharacteristics() -> [UUID] {
        [
            CSCS.measurementUUID,
            CSCS.featureUUID,
        ]
    }

    static func waitForControlPointWrite(
        on fake: FakeBluetoothCentral,
        after baseline: Int,
    ) async {
        await fake.waitForControlPointWriteCount(greaterThan: baseline)
    }

    private static func controlPointWriteCount(in calls: [FakeBluetoothCentral.RecordedCall]) -> Int {
        calls.filter { call in
            guard case let .writeValue(
                _,
                serviceUUID,
                characteristicUUID,
                _,
            ) = call else {
                return false
            }
            return serviceUUID == CSCS.serviceUUID
                && characteristicUUID == CSCS.controlPointUUID
        }.count
    }

    static func controlPointWriteCount(on fake: FakeBluetoothCentral) async -> Int {
        let calls = await fake.recordedCalls
        return controlPointWriteCount(in: calls)
    }
}

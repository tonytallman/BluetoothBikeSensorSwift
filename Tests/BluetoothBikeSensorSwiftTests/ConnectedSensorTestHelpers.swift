import BluetoothBikeSensorSwift
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
        timeoutNanoseconds: UInt64 = 1_000_000_000,
    ) async throws {
        let pollInterval: UInt64 = 5_000_000
        var elapsed: UInt64 = 0

        while elapsed < timeoutNanoseconds {
            let calls = await fake.recordedCalls
            let writeCount = calls.filter { call in
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

            if writeCount > baseline {
                return
            }

            try? await Task.sleep(nanoseconds: pollInterval)
            elapsed += pollInterval
        }

        throw ControlPointWriteTimeout()
    }

    static func controlPointWriteCount(on fake: FakeBluetoothCentral) async -> Int {
        let calls = await fake.recordedCalls
        return calls.filter { call in
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
}

private struct ControlPointWriteTimeout: Error {}

import CSCServer
import CSCWire
import Foundation

/// Shared central-side helpers for the Phase 6 suites. Older suites keep their private copies,
/// so these are methods on the fake rather than free functions with the same names.
extension FakeBluetoothPeripheral {
    nonisolated func subscribeControlPoint(server: Server, centralID: UUID) async {
        await emitSubscription(
            .subscribed(
                centralID: centralID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
            ),
        )
        await server.waitUntil(.controlPointSubscribers([centralID]))
    }

    nonisolated func unsubscribeControlPoint(centralID: UUID) async {
        await emitSubscription(
            .unsubscribed(
                centralID: centralID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
            ),
        )
    }

    nonisolated func subscribeMeasurement(server: Server, centralID: UUID) async {
        await emitSubscription(
            .subscribed(
                centralID: centralID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )
        await server.waitUntil(.measurementSubscribers([centralID]))
    }

    /// Emits a read and returns the value of its success response.
    nonisolated func read(characteristicUUID: UUID) async -> Data? {
        let requestID = UUID()
        await emitRead(
            PeripheralReadRequest(
                id: requestID,
                centralID: UUID(),
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: characteristicUUID,
                offset: 0,
            ),
        )
        await waitForRecordedCall { call in
            if case let .respond(id, _, _) = call {
                return id == requestID
            }
            return false
        }
        for call in await recordedCalls {
            if case let .respond(id, .success, value) = call, id == requestID {
                return value
            }
        }
        return nil
    }

    /// Emits a control-point write and returns the result of its response.
    @discardableResult
    nonisolated func writeControlPoint(_ transaction: PeripheralWriteTransaction) async -> ATTResult? {
        await emitWriteTransaction(transaction)
        await waitForRecordedCall { call in
            if case let .respond(id, _, _) = call {
                return id == transaction.id
            }
            return false
        }
        for call in await recordedCalls {
            if case let .respond(id, result, _) = call, id == transaction.id {
                return result
            }
        }
        return nil
    }

    nonisolated func countUpdateValues(
        characteristic: UUID,
        matching predicate: @escaping @Sendable (Data) -> Bool = { _ in true },
    ) async -> Int {
        await recordedCalls.filter { call in
            if case let .updateValue(value, _, characteristicUUID, _) = call {
                return characteristicUUID == characteristic && predicate(value)
            }
            return false
        }.count
    }

    nonisolated func waitUntilUpdateValueCount(
        _ count: Int,
        characteristic: UUID,
        matching predicate: @escaping @Sendable (Data) -> Bool = { _ in true },
    ) async {
        await waitUntilRecordedCallsSatisfy { calls in
            calls.filter { call in
                if case let .updateValue(value, _, characteristicUUID, _) = call {
                    return characteristicUUID == characteristic && predicate(value)
                }
                return false
            }.count >= count
        }
    }

    nonisolated func waitUntilCallCount(
        _ count: Int,
        matching predicate: @escaping @Sendable (RecordedCall) -> Bool,
    ) async {
        await waitUntilRecordedCallsSatisfy { calls in
            calls.filter(predicate).count >= count
        }
    }
}

func controlPointWrite(
    centralID: UUID,
    value: Data,
    transactionID: UUID = UUID(),
) -> PeripheralWriteTransaction {
    PeripheralWriteTransaction(
        id: transactionID,
        requests: [
            PeripheralWriteRequest(
                centralID: centralID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
                offset: 0,
                value: value,
            ),
        ],
    )
}

func setCumulativeValue(_ value: UInt32) -> Data {
    Data([
        0x01,
        UInt8(truncatingIfNeeded: value),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 24),
    ])
}

func updateSensorLocationValue(_ kind: SensorLocationKind) -> Data {
    Data([0x03, kind.assignedNumber])
}

let requestSupportedSensorLocationsValue = Data([0x04])

func controlPointResponse(opcode: UInt8, value: UInt8, parameter: Data = Data()) -> Data {
    CSCControlPointResponse(requestOpcode: opcode, value: value, parameter: parameter).encode()
}

func isAdd(_ call: FakeBluetoothPeripheral.RecordedCall) -> Bool {
    if case .add = call { return true }
    return false
}

func isStartAdvertising(_ call: FakeBluetoothPeripheral.RecordedCall) -> Bool {
    if case .startAdvertising = call { return true }
    return false
}

func isRemoveService(_ call: FakeBluetoothPeripheral.RecordedCall) -> Bool {
    if case .removeService = call { return true }
    return false
}

let cscAdvertiseServiceUUIDs = [CSCS.serviceUUID]

import CSCServer
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ServerNotifyQueueTests {
    @Test func subscribeThenImmediateControlPointWriteIsAccepted() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(NeverYieldingWheelSequence(), setCumulativeWheelRevolutions: delegate)
            .build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        let write = controlPointWrite(centralID: writer, value: setCumulativeValue(7))
        await fake.emitSubscription(
            .subscribed(
                centralID: writer,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
            ),
        )
        await fake.emitWriteTransaction(write)

        await fake.waitForRecordedCall { call in
            if case let .respond(id, _, _) = call {
                return id == write.id
            }
            return false
        }
        #expect(await fake.recordedCalls.contains(.respond(id: write.id, result: .success, value: nil)))
        await fake.waitUntilUpdateValueCount(
            1,
            characteristic: CSCS.controlPointUUID,
            matching: { $0 == controlPointResponse(opcode: 0x01, value: 0x01) },
        )
        #expect(await delegate.recordedValues == [7])
    }
}

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

    @Test func bufferedStartupDrainPreservesSubscribeBeforeWrite() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(NeverYieldingWheelSequence(), setCumulativeWheelRevolutions: delegate)
            .build()

        await fake.hold(.advertise)
        let startTask = Task {
            try await server.start(peripheral: fake)
        }
        await fake.waitUntilHeld(.advertise)

        let writer = UUID()
        let readID = UUID()
        await fake.emitRead(
            PeripheralReadRequest(
                id: readID,
                centralID: UUID(),
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.featureUUID,
                offset: 0,
            ),
        )
        await fake.emitSubscription(
            .subscribed(
                centralID: writer,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
            ),
        )

        await fake.hold(.respond)
        await fake.release(.advertise)
        await fake.waitUntilHeld(.respond)

        let write = controlPointWrite(centralID: writer, value: setCumulativeValue(9))
        await fake.emitWriteTransaction(write)

        await fake.release(.respond)
        try await startTask.value
        await fake.waitForRecordedCall { call in
            if case let .respond(id, _, _) = call {
                return id == write.id
            }
            return false
        }
        #expect(await fake.recordedCalls.contains(.respond(id: write.id, result: .success, value: nil)))
    }

    @Test func idleReadySignalDoesNotSkipNextPark() async throws {
        let sequence = YieldingCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(sequence).build()
        try await server.start(peripheral: fake)

        let central = UUID()
        await fake.subscribeMeasurement(server: server, centralID: central)
        await fake.emitReadyToUpdateSubscribers()
        #expect(await fake.read(characteristicUUID: CSCS.featureUUID) == Data([0x02, 0x00]))

        await fake.setNextUpdateValueAccepted(false)
        await sequence.yield(CrankRevolution(cumulativeRevolutions: 3, lastEventTime: 4))
        await fake.waitUntilUpdateValueCount(1, characteristic: CSCS.measurementUUID)
        await server.waitUntil(.readyToUpdateWaiterParked)

        #expect(await fake.countUpdateValues(characteristic: CSCS.measurementUUID) == 1)
    }

    @Test func unsubscribeDropsQueuedIndicationBehindMeasurement() async throws {
        let (server, fake, wheel) = try await Self.startWheelMultipleServer()
        let central = UUID()
        await fake.subscribeMeasurement(server: server, centralID: central)
        await fake.subscribeControlPoint(server: server, centralID: central)

        await fake.setNextUpdateValueAccepted(false)
        let sample = WheelRevolution(cumulativeRevolutions: 42, lastEventTime: 7)
        let wheelPayload = Self.wheelPayload(sample)
        await wheel.yield(sample)
        await fake.waitUntilUpdateValueCount(1, characteristic: CSCS.measurementUUID)

        await fake.emitWriteTransaction(
            controlPointWrite(centralID: central, value: requestSupportedSensorLocationsValue),
        )
        await server.waitUntil(.outboundCount(atLeast: 2))

        await fake.unsubscribeControlPoint(centralID: central)
        await server.waitUntil(.controlPointProcedureIdle)

        await fake.setNextUpdateValueAccepted(true)
        await fake.emitReadyToUpdateSubscribers()
        await fake.waitUntilUpdateValueCount(
            2,
            characteristic: CSCS.measurementUUID,
            matching: { $0 == wheelPayload },
        )
        await server.waitUntil(.acceptedMeasurementCount(atLeast: 1))

        #expect(await fake.countUpdateValues(characteristic: CSCS.controlPointUUID) == 0)
    }

    @Test func unsubscribeWhileIndicationInFlightDoesNotReEndProcedure() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(NeverYieldingWheelSequence(), setCumulativeWheelRevolutions: delegate)
            .build()
        try await server.start(peripheral: fake)
        let writer = UUID()
        await fake.subscribeControlPoint(server: server, centralID: writer)
        let success = controlPointResponse(opcode: 0x01, value: 0x01)

        await fake.hold(.updateValue)
        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: setCumulativeValue(1))) == .success)
        await fake.waitUntilHeld(.updateValue)

        await fake.unsubscribeControlPoint(centralID: writer)
        await server.waitUntil(.controlPointProcedureIdle)
        await fake.release(.updateValue)

        await fake.subscribeControlPoint(server: server, centralID: writer)
        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: setCumulativeValue(2))) == .success)
        await fake.waitUntilUpdateValueCount(2, characteristic: CSCS.controlPointUUID, matching: { $0 == success })
        await server.waitUntil(.controlPointProcedureIdle)

        #expect(await fake.countUpdateValues(characteristic: CSCS.controlPointUUID, matching: { $0 == success }) == 2)
        #expect(await delegate.recordedValues == [1, 2])
    }

    @Test func unsubscribeDuringHeldFalseUpdateValueDropsHeadWithoutReady() async throws {
        let wheel = YieldingWheelSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(wheel, setCumulativeWheelRevolutions: ScriptedCumulativeDelegate())
            .build()
        try await server.start(peripheral: fake)
        let central = UUID()
        await fake.subscribeMeasurement(server: server, centralID: central)

        await fake.hold(.updateValue)
        await wheel.yield(WheelRevolution(cumulativeRevolutions: 1, lastEventTime: 1))
        await fake.waitUntilHeld(.updateValue)

        await fake.emitSubscription(
            .unsubscribed(
                centralID: central,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )
        await server.waitUntil(.measurementSubscribers([]))

        await fake.setNextUpdateValueAccepted(false)
        await fake.release(.updateValue)
        await wheel.waitUntilNextEntered(count: 2)

        await fake.subscribeMeasurement(server: server, centralID: central)
        await fake.setNextUpdateValueAccepted(true)
        let sample = WheelRevolution(cumulativeRevolutions: 2, lastEventTime: 2)
        await wheel.yield(sample)
        await fake.waitUntilUpdateValueCount(
            1,
            characteristic: CSCS.measurementUUID,
            matching: { $0 == Self.wheelPayload(sample) },
        )
    }

    @Test func otherCentralUnsubscribeKeepsQueuedIndication() async throws {
        let (server, fake, wheel) = try await Self.startWheelMultipleServer()
        let writer = UUID()
        let other = UUID()
        await fake.subscribeMeasurement(server: server, centralID: writer)
        await fake.subscribeControlPoint(server: server, centralID: writer)
        await fake.emitSubscription(
            .subscribed(
                centralID: other,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
            ),
        )
        await server.waitUntil(.controlPointSubscribers([writer, other]))

        await fake.setNextUpdateValueAccepted(false)
        let sample = WheelRevolution(cumulativeRevolutions: 42, lastEventTime: 7)
        await wheel.yield(sample)
        await fake.waitUntilUpdateValueCount(1, characteristic: CSCS.measurementUUID)

        await fake.emitWriteTransaction(
            controlPointWrite(centralID: writer, value: requestSupportedSensorLocationsValue),
        )
        await server.waitUntil(.outboundCount(atLeast: 2))

        await fake.unsubscribeControlPoint(centralID: other)
        await server.waitUntil(.controlPointSubscribers([writer]))

        await fake.setNextUpdateValueAccepted(true)
        await fake.emitReadyToUpdateSubscribers()
        let requestResponse = controlPointResponse(opcode: 0x04, value: 0x01, parameter: Data([0x05, 0x06]))
        await fake.waitUntilUpdateValueCount(
            1,
            characteristic: CSCS.controlPointUUID,
            matching: { $0 == requestResponse },
        )
        await server.waitUntil(.controlPointProcedureIdle)
        #expect(await fake.countUpdateValues(characteristic: CSCS.measurementUUID, matching: { $0 == Self.wheelPayload(sample) }) == 2)
    }

    private static func startWheelMultipleServer() async throws -> (Server, FakeBluetoothPeripheral, YieldingWheelSequence) {
        let wheel = YieldingWheelSequence()
        let locations = ScriptedLocationDelegate(supported: [.leftCrank, .rightCrank], current: .leftCrank)
        let server = Server.wheelRevolutions(wheel, setCumulativeWheelRevolutions: ScriptedCumulativeDelegate())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)
        return (server, fake, wheel)
    }

    private static func wheelPayload(_ sample: WheelRevolution) -> Data {
        CSCMeasurement(
            cumulativeWheelRevolutions: sample.cumulativeRevolutions,
            lastWheelEventTime: sample.lastEventTime,
        ).encode()!
    }
}

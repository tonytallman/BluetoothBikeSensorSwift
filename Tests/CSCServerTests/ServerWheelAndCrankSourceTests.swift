import CSCServer
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ServerWheelAndCrankSourceTests {
    @Test func eachElementSendsOneNotificationWithBothHalves() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (sequence, yield) = makeYieldingWheelAndCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelAndCrankRevolutions(sequence, setCumulativeWheelRevolutions: delegate)
            .build()
        try await server.start(peripheral: fake)
        let central = UUID()
        await fake.subscribeMeasurement(server: server, centralID: central)

        let e1 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 10, lastEventTime: 100),
            crank: CrankRevolution(cumulativeRevolutions: 5, lastEventTime: 200),
        )
        await yield(e1)
        await server.waitUntil(.acceptedMeasurementCount(atLeast: 1))

        let e2 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 11, lastEventTime: 101),
            crank: CrankRevolution(cumulativeRevolutions: 6, lastEventTime: 201),
        )
        await yield(e2)
        await server.waitUntil(.acceptedMeasurementCount(atLeast: 2))

        #expect(await measurementPayloads(fake) == [encoded(e1), encoded(e2)])
        await server.stop()
    }

    @Test func setCumulativeValueCallsDelegateAndIndicatesSuccess() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (sequence, _) = makeYieldingWheelAndCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelAndCrankRevolutions(sequence, setCumulativeWheelRevolutions: delegate)
            .build()
        try await server.start(peripheral: fake)
        let writer = UUID()
        await fake.subscribeMeasurement(server: server, centralID: writer)
        await fake.subscribeControlPoint(server: server, centralID: writer)

        #expect(await fake.writeControlPoint(
            controlPointWrite(centralID: writer, value: setCumulativeValue(0x12345678)),
        ) == .success)
        await delegate.waitUntilRecordedCount(1)
        await fake.waitUntilUpdateValueCount(
            1,
            characteristic: CSCS.controlPointUUID,
            matching: { $0 == controlPointResponse(opcode: 0x01, value: 0x01) },
        )
        await server.stop()
    }

    @Test func malformedSetCumulativeValueIsInvalidParameter() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (sequence, _) = makeYieldingWheelAndCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelAndCrankRevolutions(sequence, setCumulativeWheelRevolutions: delegate)
            .build()
        try await server.start(peripheral: fake)
        let writer = UUID()
        await fake.subscribeControlPoint(server: server, centralID: writer)

        #expect(await fake.writeControlPoint(
            controlPointWrite(centralID: writer, value: Data([0x01])),
        ) == .success)
        await fake.waitUntilUpdateValueCount(
            1,
            characteristic: CSCS.controlPointUUID,
            matching: { $0 == controlPointResponse(opcode: 0x01, value: 0x03) },
        )
        await server.stop()
    }

    @Test func setCumulativeValueDelegateFailureIndicatesOperationFailed() async throws {
        let delegate = ScriptedCumulativeDelegate()
        await delegate.setShouldThrow(true)
        let (sequence, yield) = makeYieldingWheelAndCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelAndCrankRevolutions(sequence, setCumulativeWheelRevolutions: delegate)
            .build()
        try await server.start(peripheral: fake)
        let writer = UUID()
        await fake.subscribeMeasurement(server: server, centralID: writer)
        await fake.subscribeControlPoint(server: server, centralID: writer)

        #expect(await fake.writeControlPoint(
            controlPointWrite(centralID: writer, value: setCumulativeValue(1)),
        ) == .success)
        await fake.waitUntilUpdateValueCount(
            1,
            characteristic: CSCS.controlPointUUID,
            matching: { $0 == controlPointResponse(opcode: 0x01, value: 0x04) },
        )
        await server.waitUntil(.controlPointProcedureIdle)

        await delegate.setShouldThrow(false)
        let e2 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 2, lastEventTime: 3),
            crank: CrankRevolution(cumulativeRevolutions: 4, lastEventTime: 5),
        )
        await yield(e2)
        await fake.waitUntilUpdateValueCount(
            1,
            characteristic: CSCS.measurementUUID,
            matching: { $0 == encoded(e2) },
        )
        await server.stop()
    }

    @Test func setCumulativeValueRequeuesQueuedElementCrankOnly() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (sequence, yield) = makeYieldingWheelAndCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelAndCrankRevolutions(sequence, setCumulativeWheelRevolutions: delegate)
            .build()
        try await server.start(peripheral: fake)
        let writer = UUID()
        await fake.subscribeMeasurement(server: server, centralID: writer)
        await fake.subscribeControlPoint(server: server, centralID: writer)

        let e1 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 50, lastEventTime: 1),
            crank: CrankRevolution(cumulativeRevolutions: 10, lastEventTime: 2),
        )
        await yield(e1)
        await server.waitUntil(.acceptedMeasurementCount(atLeast: 1))

        await fake.setNextUpdateValueAccepted(false)
        let e2 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 51, lastEventTime: 3),
            crank: CrankRevolution(cumulativeRevolutions: 11, lastEventTime: 4),
        )
        await yield(e2)
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.measurementUUID, _) = call {
                return value == encoded(e2)
            }
            return false
        }

        let setCumulativeID = UUID()
        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: setCumulativeID,
                requests: [
                    PeripheralWriteRequest(
                        centralID: writer,
                        serviceUUID: CSCS.serviceUUID,
                        characteristicUUID: CSCS.controlPointUUID,
                        offset: 0,
                        value: Data([0x01, 0x78, 0x56, 0x34, 0x12]),
                    ),
                ],
            ),
        )
        await fake.waitForRecordedCall { call in
            if case let .respond(id, .success, nil) = call {
                return id == setCumulativeID
            }
            return false
        }

        let crankOnly = CSCMeasurement(
            cumulativeCrankRevolutions: e2.crank.cumulativeRevolutions,
            lastCrankEventTime: e2.crank.lastEventTime,
        ).encode()!
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.measurementUUID, _) = call {
                return value == crankOnly
            }
            return false
        }

        await fake.setNextUpdateValueAccepted(true)
        await fake.emitReadyToUpdateSubscribers()
        await server.waitUntil(.controlPointProcedureIdle)
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == controlPointResponse(opcode: 0x01, value: 0x01)
            }
            return false
        }

        let e3 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 60, lastEventTime: 10),
            crank: CrankRevolution(cumulativeRevolutions: 20, lastEventTime: 11),
        )
        await yield(e3)
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.measurementUUID, _) = call {
                return value == encoded(e3)
            }
            return false
        }

        let payloads = await measurementPayloads(fake)
        #expect(payloads.first == encoded(e1))
        #expect(payloads.contains(encoded(e2)))
        #expect(payloads.contains(crankOnly))
        #expect(payloads.last == encoded(e3))
        await server.stop()
    }

    @Test func setCumulativeValueDuringInFlightSendKeepsOriginalPayload() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (sequence, yield) = makeYieldingWheelAndCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelAndCrankRevolutions(sequence, setCumulativeWheelRevolutions: delegate)
            .build()
        try await server.start(peripheral: fake)
        let writer = UUID()
        await fake.subscribeMeasurement(server: server, centralID: writer)
        await fake.subscribeControlPoint(server: server, centralID: writer)

        await fake.hold(.updateValue)
        let e1 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 1, lastEventTime: 2),
            crank: CrankRevolution(cumulativeRevolutions: 3, lastEventTime: 4),
        )
        await yield(e1)
        await fake.waitUntilHeld(.updateValue)

        #expect(await fake.writeControlPoint(
            controlPointWrite(centralID: writer, value: setCumulativeValue(9)),
        ) == .success)
        await server.waitUntil(.outboundCount(atLeast: 2))

        await fake.release(.updateValue)
        await server.waitUntil(.controlPointProcedureIdle)
        await fake.waitUntilUpdateValueCount(
            1,
            characteristic: CSCS.controlPointUUID,
            matching: { $0 == controlPointResponse(opcode: 0x01, value: 0x01) },
        )

        let e2 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 2, lastEventTime: 5),
            crank: CrankRevolution(cumulativeRevolutions: 4, lastEventTime: 6),
        )
        await yield(e2)
        await fake.waitUntilUpdateValueCount(
            1,
            characteristic: CSCS.measurementUUID,
            matching: { $0 == encoded(e2) },
        )

        #expect(await measurementPayloads(fake) == [encoded(e1), encoded(e2)])
        await server.stop()
    }

    @Test func elementWithoutSubscribersIsDropped() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let sequence = YieldingWheelAndCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelAndCrankRevolutions(sequence, setCumulativeWheelRevolutions: delegate)
            .build()
        try await server.start(peripheral: fake)

        let e1 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 1, lastEventTime: 2),
            crank: CrankRevolution(cumulativeRevolutions: 3, lastEventTime: 4),
        )
        await sequence.yield(e1)
        await sequence.waitUntilNextEntered(count: 2)

        let central = UUID()
        await fake.subscribeMeasurement(server: server, centralID: central)
        let e2 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 5, lastEventTime: 6),
            crank: CrankRevolution(cumulativeRevolutions: 7, lastEventTime: 8),
        )
        await sequence.yield(e2)
        await fake.waitUntilUpdateValueCount(
            1,
            characteristic: CSCS.measurementUUID,
            matching: { $0 == encoded(e2) },
        )

        #expect(await measurementPayloads(fake) == [encoded(e2)])
        await server.stop()
    }

    @Test func backpressureRetriesSameBothHalvesPayload() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (sequence, yield) = makeYieldingWheelAndCrankSequence()
        let fake = FakeBluetoothPeripheral()
        await fake.setNextUpdateValueAccepted(false)
        let server = Server.wheelAndCrankRevolutions(sequence, setCumulativeWheelRevolutions: delegate)
            .build()
        try await server.start(peripheral: fake)
        let central = UUID()
        await fake.subscribeMeasurement(server: server, centralID: central)

        let e1 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 9, lastEventTime: 10),
            crank: CrankRevolution(cumulativeRevolutions: 11, lastEventTime: 12),
        )
        await yield(e1)
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.measurementUUID, _) = call {
                return value == encoded(e1)
            }
            return false
        }
        await server.waitUntil(.readyToUpdateWaiterParked)

        let e2 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 20, lastEventTime: 21),
            crank: CrankRevolution(cumulativeRevolutions: 22, lastEventTime: 23),
        )
        await yield(e2)

        await fake.setNextUpdateValueAccepted(true)
        await fake.emitReadyToUpdateSubscribers()
        await fake.waitUntilUpdateValueCount(
            1,
            characteristic: CSCS.measurementUUID,
            matching: { $0 == encoded(e2) },
        )

        #expect(await measurementPayloads(fake) == [encoded(e1), encoded(e1), encoded(e2)])
        await server.stop()
    }

    @Test func radioLossDropsElementsUntilResubscribe() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (sequence, yield) = makeYieldingWheelAndCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelAndCrankRevolutions(sequence, setCumulativeWheelRevolutions: delegate)
            .build()
        try await server.start(peripheral: fake)
        let central = UUID()
        await fake.subscribeMeasurement(server: server, centralID: central)

        let e1 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 1, lastEventTime: 10),
            crank: CrankRevolution(cumulativeRevolutions: 2, lastEventTime: 20),
        )
        await yield(e1)
        await server.waitUntil(.acceptedMeasurementCount(atLeast: 1))

        await fake.setState(.poweredOff)
        await server.waitUntil(.measurementSubscribers([]))

        let e2 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 3, lastEventTime: 30),
            crank: CrankRevolution(cumulativeRevolutions: 4, lastEventTime: 40),
        )
        await yield(e2)
        await sequence.waitUntilNextEntered(count: 3)

        await fake.setState(.poweredOn)
        await fake.waitUntilCallCount(2, matching: isStartAdvertising)
        await fake.subscribeMeasurement(server: server, centralID: central)

        let e3 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 5, lastEventTime: 50),
            crank: CrankRevolution(cumulativeRevolutions: 6, lastEventTime: 60),
        )
        await yield(e3)
        await fake.waitUntilUpdateValueCount(
            1,
            characteristic: CSCS.measurementUUID,
            matching: { $0 == encoded(e3) },
        )

        #expect(await measurementPayloads(fake) == [encoded(e1), encoded(e3)])
        await server.stop()
    }

    @Test func stopCancelsWheelAndCrankIteration() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let sequence = YieldingWheelAndCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelAndCrankRevolutions(sequence, setCumulativeWheelRevolutions: delegate)
            .build()
        try await server.start(peripheral: fake)
        await server.stop()
        #expect(await sequence.iterationWasCancelled())
    }
}

private func encoded(_ element: WheelAndCrankRevolution) -> Data {
    CSCMeasurement(
        cumulativeWheelRevolutions: element.wheel.cumulativeRevolutions,
        lastWheelEventTime: element.wheel.lastEventTime,
        cumulativeCrankRevolutions: element.crank.cumulativeRevolutions,
        lastCrankEventTime: element.crank.lastEventTime,
    ).encode()!
}

private func measurementPayloads(_ fake: FakeBluetoothPeripheral) async -> [Data] {
    await fake.recordedCalls.compactMap { call in
        if case let .updateValue(value, _, CSCS.measurementUUID, _) = call {
            return value
        }
        return nil
    }
}

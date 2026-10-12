import CSCServer
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ServerWheelAndCrankSourceTests {
    @Test func eachElementSendsOneNotificationWithItsHalves() async throws {
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
        let e2 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 11, lastEventTime: 101),
        )
        let e3 = WheelAndCrankRevolution(
            crank: CrankRevolution(cumulativeRevolutions: 6, lastEventTime: 201),
        )
        await yield(e1)
        await server.waitUntil(.acceptedMeasurementCount(atLeast: 1))
        await yield(e2)
        await server.waitUntil(.acceptedMeasurementCount(atLeast: 2))
        await yield(e3)
        await server.waitUntil(.acceptedMeasurementCount(atLeast: 3))

        #expect(await fake.measurementPayloads() == [encoded(e1), encoded(e2), encoded(e3)])
        await server.stop()
    }

    @Test func elementWithNeitherHalfIsDropped() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (sequence, yield) = makeYieldingWheelAndCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelAndCrankRevolutions(sequence, setCumulativeWheelRevolutions: delegate)
            .build()
        try await server.start(peripheral: fake)
        let central = UUID()
        await fake.subscribeMeasurement(server: server, centralID: central)

        await yield(WheelAndCrankRevolution())
        let e = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 1, lastEventTime: 2),
            crank: CrankRevolution(cumulativeRevolutions: 3, lastEventTime: 4),
        )
        await yield(e)
        await fake.waitUntilUpdateValueCount(1, characteristic: CSCS.measurementUUID)
        #expect(await fake.measurementPayloads() == [encoded(e)])
        await server.stop()
    }

    @Test func elementWithoutSubscribersIsDropped() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let sequence = YieldingWheelAndCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelAndCrankRevolutions(sequence, setCumulativeWheelRevolutions: delegate)
            .build()
        try await server.start(peripheral: fake)

        await sequence.yield(
            WheelAndCrankRevolution(
                wheel: WheelRevolution(cumulativeRevolutions: 1, lastEventTime: 2),
                crank: CrankRevolution(cumulativeRevolutions: 3, lastEventTime: 4),
            ),
        )
        await sequence.waitUntilNextEntered(count: 2)

        let central = UUID()
        await fake.subscribeMeasurement(server: server, centralID: central)
        let e2 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 5, lastEventTime: 6),
            crank: CrankRevolution(cumulativeRevolutions: 7, lastEventTime: 8),
        )
        await sequence.yield(e2)
        await fake.waitUntilUpdateValueCount(1, characteristic: CSCS.measurementUUID)
        #expect(await fake.measurementPayloads() == [encoded(e2)])
        await server.stop()
    }

    @Test func backpressureRetriesSameBytesBeforeNextElement() async throws {
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
        let e2 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 20, lastEventTime: 21),
            crank: CrankRevolution(cumulativeRevolutions: 22, lastEventTime: 23),
        )
        await yield(e1)
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.measurementUUID, _) = call {
                return value == encoded(e1)
            }
            return false
        }
        await yield(e2)
        await fake.setNextUpdateValueAccepted(true)
        await fake.emitReadyToUpdateSubscribers()
        await fake.waitUntilUpdateValueCount(1, characteristic: CSCS.measurementUUID, matching: { $0 == encoded(e2) })
        #expect(await fake.measurementPayloads() == [encoded(e1), encoded(e1), encoded(e2)])
        await server.stop()
    }

    @Test func radioLossDropsElementYieldedWhileSuspended() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (sequence, yield) = makeYieldingWheelAndCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelAndCrankRevolutions(sequence, setCumulativeWheelRevolutions: delegate)
            .build()
        try await server.start(peripheral: fake)
        let central = UUID()
        await fake.subscribeMeasurement(server: server, centralID: central)

        await fake.setState(.poweredOff)
        await server.waitUntil(.measurementSubscribers([]))

        let e1 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 1, lastEventTime: 10),
            crank: CrankRevolution(cumulativeRevolutions: 2, lastEventTime: 20),
        )
        await yield(e1)
        await sequence.waitUntilNextEntered(count: 2)

        await fake.setState(.poweredOn)
        await fake.waitUntilCallCount(2, matching: isStartAdvertising)
        await fake.subscribeMeasurement(server: server, centralID: central)

        let e2 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 5, lastEventTime: 50),
            crank: CrankRevolution(cumulativeRevolutions: 6, lastEventTime: 60),
        )
        await yield(e2)
        await fake.waitUntilUpdateValueCount(1, characteristic: CSCS.measurementUUID)
        #expect(await fake.measurementPayloads() == [encoded(e2)])
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

    @Test func malformedSetCumulativeValueIndicatesInvalidParameter() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (sequence, _) = makeYieldingWheelAndCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelAndCrankRevolutions(sequence, setCumulativeWheelRevolutions: delegate)
            .build()
        try await server.start(peripheral: fake)
        let writer = UUID()
        await fake.subscribeControlPoint(server: server, centralID: writer)

        #expect(await fake.writeControlPoint(
            controlPointWrite(centralID: writer, value: Data([0x01, 0x00, 0x00, 0x00])),
        ) == .success)
        await fake.waitUntilUpdateValueCount(
            1,
            characteristic: CSCS.controlPointUUID,
            matching: { $0 == controlPointResponse(opcode: 0x01, value: 0x03) },
        )
        await server.stop()
    }

    @Test func delegateThrowKeepsQueuedElement() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (sequence, yield) = makeYieldingWheelAndCrankSequence()
        let fake = FakeBluetoothPeripheral()
        await fake.setNextUpdateValueAccepted(false)
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
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.measurementUUID, _) = call {
                return value == encoded(e1)
            }
            return false
        }

        await delegate.setShouldThrow(true)
        await fake.emitWriteTransaction(
            controlPointWrite(centralID: writer, value: setCumulativeValue(1)),
        )
        await server.waitUntil(.outboundCount(atLeast: 2))

        await fake.setNextUpdateValueAccepted(true)
        await fake.emitReadyToUpdateSubscribers()
        await fake.waitUntilUpdateValueCount(
            1,
            characteristic: CSCS.controlPointUUID,
            matching: { $0 == controlPointResponse(opcode: 0x01, value: 0x04) },
        )
        #expect(await fake.measurementPayloads() == [encoded(e1), encoded(e1)])
        await server.stop()
    }

    @Test func setCumulativeValueResendsQueuedElementCrankOnly() async throws {
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
        await fake.setNextUpdateValueAccepted(false)
        await yield(e1)
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.measurementUUID, _) = call {
                return value == encoded(e1)
            }
            return false
        }

        let crankOnly = CSCMeasurement(cumulativeCrankRevolutions: 10, lastCrankEventTime: 2).encode()!
        await fake.emitWriteTransaction(
            controlPointWrite(centralID: writer, value: setCumulativeValue(0x12345678)),
        )
        await fake.waitForRecordedCall { call in
            if case .respond(_, .success, nil) = call { return true }
            return false
        }
        await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.filter { call in
                if case let .updateValue(value, _, CSCS.measurementUUID, _) = call {
                    return value == crankOnly
                }
                return false
            }.count >= 1
        }
        await fake.emitReadyToUpdateSubscribers()
        await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.filter { call in
                if case let .updateValue(value, _, CSCS.measurementUUID, _) = call {
                    return value == crankOnly
                }
                return false
            }.count >= 2
        }
        await fake.setNextUpdateValueAccepted(true)
        await fake.emitReadyToUpdateSubscribers()
        await server.waitUntil(.controlPointProcedureIdle)
        await fake.waitUntilUpdateValueCount(
            1,
            characteristic: CSCS.controlPointUUID,
            matching: { $0 == controlPointResponse(opcode: 0x01, value: 0x01) },
        )

        let e2 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 0, lastEventTime: 4),
            crank: CrankRevolution(cumulativeRevolutions: 11, lastEventTime: 3),
        )
        await yield(e2)
        await fake.waitUntilUpdateValueCount(1, characteristic: CSCS.measurementUUID, matching: { $0 == encoded(e2) })
        let payloads = await fake.measurementPayloads()
        #expect(payloads == [encoded(e1), crankOnly, crankOnly, crankOnly, encoded(e2)])
        await server.stop()
    }

    @Test func setCumulativeValueDropsQueuedWheelOnlyElement() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (sequence, yield) = makeYieldingWheelAndCrankSequence()
        let fake = FakeBluetoothPeripheral()
        await fake.setNextUpdateValueAccepted(false)
        let server = Server.wheelAndCrankRevolutions(sequence, setCumulativeWheelRevolutions: delegate)
            .build()
        try await server.start(peripheral: fake)
        let writer = UUID()
        await fake.subscribeMeasurement(server: server, centralID: writer)
        await fake.subscribeControlPoint(server: server, centralID: writer)

        let wheelOnly = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 42, lastEventTime: 7),
        )
        let wheelPayload = encoded(wheelOnly)
        await yield(wheelOnly)
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.measurementUUID, _) = call {
                return value == wheelPayload
            }
            return false
        }

        await fake.emitWriteTransaction(
            controlPointWrite(centralID: writer, value: setCumulativeValue(0x12345678)),
        )
        await fake.waitUntilUpdateValueCount(
            1,
            characteristic: CSCS.controlPointUUID,
            matching: { $0 == controlPointResponse(opcode: 0x01, value: 0x01) },
        )
        await fake.setNextUpdateValueAccepted(true)
        await fake.emitReadyToUpdateSubscribers()
        await server.waitUntil(.controlPointProcedureIdle)

        let attempts = await fake.countUpdateValues(characteristic: CSCS.measurementUUID, matching: { $0 == wheelPayload })
        #expect(attempts == 1)
        await server.stop()
    }

    @Test func inFlightSetCumulativeValueSendsOriginalBytesOnce() async throws {
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

        await fake.emitWriteTransaction(
            controlPointWrite(centralID: writer, value: setCumulativeValue(9)),
        )
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .success, nil) = call { return true }
            return false
        }
        await server.waitUntil(.outboundCount(atLeast: 2))

        await fake.release(.updateValue)
        await server.waitUntil(.controlPointProcedureIdle)

        let e2 = WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 2, lastEventTime: 5),
            crank: CrankRevolution(cumulativeRevolutions: 4, lastEventTime: 6),
        )
        await yield(e2)
        await fake.waitUntilUpdateValueCount(1, characteristic: CSCS.measurementUUID, matching: { $0 == encoded(e2) })
        #expect(await fake.measurementPayloads() == [encoded(e1), encoded(e2)])
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
        cumulativeWheelRevolutions: element.wheel?.cumulativeRevolutions,
        lastWheelEventTime: element.wheel?.lastEventTime,
        cumulativeCrankRevolutions: element.crank?.cumulativeRevolutions,
        lastCrankEventTime: element.crank?.lastEventTime,
    ).encode()!
}

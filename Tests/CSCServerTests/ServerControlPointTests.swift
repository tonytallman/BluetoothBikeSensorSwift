import CSCServer
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ServerControlPointTests {
    @Test func setCumulativeIndicatesSuccessAndForwardsUInt32() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeMeasurement(fake: fake, server: server, centralID: writer)
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        let transactionID = UUID()
        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: transactionID,
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
                return id == transactionID
            }
            return false
        }
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, characteristicUUID, .only(centrals)) = call {
                return characteristicUUID == CSCS.controlPointUUID
                    && centrals == [writer]
                    && value == CSCControlPointResponse(
                        requestOpcode: 0x01,
                        value: 0x01,
                        parameter: Data(),
                    ).encode()
            }
            return false
        }

        #expect(await delegate.recordedValues == [0x12345678])
        await server.waitUntilControlPointProcedureIdle()

        let measurementUpdates = await fake.recordedCalls.filter { call in
            if case .updateValue(_, _, CSCS.measurementUUID, _) = call { return true }
            return false
        }
        #expect(measurementUpdates.isEmpty)
    }

    @Test func delegateThrowIndicatesOperationFailed() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (wheelSequence, yieldWheel) = makeYieldingWheelSequence()
        let (crankSequence, yieldCrank) = makeYieldingCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(wheelSequence, setCumulativeWheelRevolutions: delegate)
            .crankRevolutions(crankSequence)
            .build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeMeasurement(fake: fake, server: server, centralID: writer)
        await yieldWheel(WheelRevolution(cumulativeRevolutions: 50, lastEventTime: 1))
        await server.waitUntilAcceptedMeasurementCount(1)

        await fake.setNextUpdateValueAccepted(false)
        await delegate.setShouldThrow(true)
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(controlPointWrite(centralID: writer))
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x01,
                    value: 0x04,
                    parameter: Data(),
                ).encode()
            }
            return false
        }

        await fake.emitWriteTransaction(controlPointWrite(centralID: writer))
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .error(0x80), nil) = call { return true }
            return false
        }
        #expect(await delegate.recordedValues.count == 1)

        await fake.setNextUpdateValueAccepted(true)
        await fake.emitReadyToUpdateSubscribers()
        await server.waitUntilControlPointProcedureIdle()

        await yieldCrank(CrankRevolution(cumulativeRevolutions: 10, lastEventTime: 2))
        await server.waitUntilAcceptedMeasurementCount(2)

        let expected = CSCMeasurement(
            cumulativeWheelRevolutions: 50,
            lastWheelEventTime: 1,
            cumulativeCrankRevolutions: 10,
            lastCrankEventTime: 2,
        ).encode()!
        await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.contains { call in
                if case let .updateValue(value, _, CSCS.measurementUUID, _) = call {
                    return value == expected
                }
                return false
            }
        }

        await fake.emitWriteTransaction(controlPointWrite(centralID: writer))
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .success, nil) = call { return true }
            return false
        }
    }

    @Test func writeWithoutControlPointSubscriptionReturns0x81() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        let transactionID = UUID()
        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: transactionID,
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
            if case let .respond(id, .error(0x81), nil) = call {
                return id == transactionID
            }
            return false
        }
        #expect(await delegate.recordedValues.isEmpty)
        let cpUpdates = await fake.recordedCalls.filter { call in
            if case .updateValue(_, _, CSCS.controlPointUUID, _) = call { return true }
            return false
        }
        #expect(cpUpdates.isEmpty)
    }

    @Test func measurementSubscriptionDoesNotSatisfyControlPointCCCD() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await fake.emitSubscription(
            .subscribed(
                centralID: writer,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )
        await server.waitForMeasurementSubscribers([writer])

        let transactionID = UUID()
        await fake.emitWriteTransaction(controlPointWrite(centralID: writer, transactionID: transactionID))
        await fake.waitForRecordedCall { call in
            if case let .respond(id, .error(0x81), nil) = call {
                return id == transactionID
            }
            return false
        }
    }

    @Test func secondCentralWithoutSubscriptionGets0x81DuringInProgressProcedure() async throws {
        let delegate = ScriptedCumulativeDelegate()
        await delegate.armParkForNextCall()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let centralA = UUID()
        let centralB = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: centralA)

        await fake.emitWriteTransaction(controlPointWrite(centralID: centralA))
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .success, nil) = call { return true }
            return false
        }

        await fake.emitWriteTransaction(controlPointWrite(centralID: centralB))
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .error(0x81), nil) = call { return true }
            return false
        }
        #expect(await delegate.recordedValues.count == 1)

        await delegate.release()
        await server.waitUntilControlPointProcedureIdle()
    }

    @Test func calibrationIndicatesOpCodeNotSupported() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: UUID(),
                requests: [
                    PeripheralWriteRequest(
                        centralID: writer,
                        serviceUUID: CSCS.serviceUUID,
                        characteristicUUID: CSCS.controlPointUUID,
                        offset: 0,
                        value: Data([0x02]),
                    ),
                ],
            ),
        )

        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x02,
                    value: 0x02,
                    parameter: Data(),
                ).encode()
            }
            return false
        }
        #expect(await delegate.recordedValues.isEmpty)
    }

    @Test func secondWriteWhileDelegateParkedReturnsProcedureInProgress() async throws {
        let delegate = ScriptedCumulativeDelegate()
        await delegate.armParkForNextCall()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(controlPointWrite(centralID: writer))
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .success, nil) = call { return true }
            return false
        }
        await delegate.waitUntilRecordedCount(1)

        await fake.emitWriteTransaction(controlPointWrite(centralID: writer))
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .error(0x80), nil) = call { return true }
            return false
        }
        #expect(await delegate.recordedValues.count == 1)

        await delegate.release()
        await server.waitUntilControlPointProcedureIdle()

        let indicationCountBeforeThird = await fake.recordedCalls.filter { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x01,
                    value: 0x01,
                    parameter: Data(),
                ).encode()
            }
            return false
        }.count
        #expect(indicationCountBeforeThird == 1)

        let write3ID = UUID()
        await fake.emitWriteTransaction(controlPointWrite(centralID: writer, transactionID: write3ID))
        await fake.waitForRecordedCall { call in
            if case let .respond(id, .success, nil) = call {
                return id == write3ID
            }
            return false
        }
        await server.waitUntilControlPointProcedureIdle()

        let indicationCount = await fake.recordedCalls.filter { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x01,
                    value: 0x01,
                    parameter: Data(),
                ).encode()
            }
            return false
        }.count
        #expect(indicationCount == 2)
        #expect(await delegate.recordedValues.count == 2)
    }

    @Test func procedureStaysInProgressWhileIndicationIsBackpressured() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        await fake.setNextUpdateValueAccepted(false)
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(controlPointWrite(centralID: writer))
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x01,
                    value: 0x01,
                    parameter: Data(),
                ).encode()
            }
            return false
        }

        await fake.emitWriteTransaction(controlPointWrite(centralID: writer))
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .error(0x80), nil) = call { return true }
            return false
        }
        #expect(await delegate.recordedValues.count == 1)

        await fake.setNextUpdateValueAccepted(true)
        await fake.emitReadyToUpdateSubscribers()
        await server.waitUntilControlPointProcedureIdle()

        let write3ID = UUID()
        await fake.emitWriteTransaction(controlPointWrite(centralID: writer, transactionID: write3ID))
        await fake.waitForRecordedCall { call in
            if case let .respond(id, .success, nil) = call {
                return id == write3ID
            }
            return false
        }
    }

    @Test func backpressuredIndicationDroppedWhenWriterUnsubscribes() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        await fake.setNextUpdateValueAccepted(false)
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        let secondCentral = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)
        await fake.emitSubscription(
            .subscribed(
                centralID: secondCentral,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
            ),
        )
        await server.waitForControlPointSubscribers([writer, secondCentral])

        await fake.emitWriteTransaction(controlPointWrite(centralID: writer))
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x01,
                    value: 0x01,
                    parameter: Data(),
                ).encode()
            }
            return false
        }

        await fake.emitSubscription(
            .unsubscribed(
                centralID: writer,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
            ),
        )
        await server.waitUntilControlPointProcedureIdle()

        await fake.setNextUpdateValueAccepted(true)

        let secondWriteID = UUID()
        await fake.emitWriteTransaction(controlPointWrite(centralID: secondCentral, transactionID: secondWriteID))
        await fake.waitForRecordedCall { call in
            if case let .respond(id, .success, nil) = call {
                return id == secondWriteID
            }
            return false
        }
        await server.waitUntilControlPointProcedureIdle()
    }

    @Test func locationProceduresIndicateOpCodeNotSupported() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: UUID(),
                requests: [
                    PeripheralWriteRequest(
                        centralID: writer,
                        serviceUUID: CSCS.serviceUUID,
                        characteristicUUID: CSCS.controlPointUUID,
                        offset: 0,
                        value: Data([0x03, 0x05]),
                    ),
                ],
            ),
        )
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, _, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x03,
                    value: 0x02,
                    parameter: Data(),
                ).encode()
            }
            return false
        }
        await server.waitUntilControlPointProcedureIdle()

        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: UUID(),
                requests: [
                    PeripheralWriteRequest(
                        centralID: writer,
                        serviceUUID: CSCS.serviceUUID,
                        characteristicUUID: CSCS.controlPointUUID,
                        offset: 0,
                        value: Data([0x04]),
                    ),
                ],
            ),
        )
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, _, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x04,
                    value: 0x02,
                    parameter: Data(),
                ).encode()
            }
            return false
        }
        #expect(await delegate.recordedValues.isEmpty)
    }

    @Test func excludedOpcodesWithWrongParameterLengthIndicateOpCodeNotSupported() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        let bodies: [(Data, UInt8)] = [
            (Data([0x02, 0xFF]), 0x02),
            (Data([0x03]), 0x03),
            (Data([0x03, 0x05, 0xFF]), 0x03),
            (Data([0x04, 0x00]), 0x04),
        ]

        for (body, opcode) in bodies {
            let transactionID = UUID()
            let expectedIndication = CSCControlPointResponse(
                requestOpcode: opcode,
                value: 0x02,
                parameter: Data(),
            ).encode()
            await fake.emitWriteTransaction(
                PeripheralWriteTransaction(
                    id: transactionID,
                    requests: [
                        PeripheralWriteRequest(
                            centralID: writer,
                            serviceUUID: CSCS.serviceUUID,
                            characteristicUUID: CSCS.controlPointUUID,
                            offset: 0,
                            value: body,
                        ),
                    ],
                ),
            )
            await fake.waitForRecordedCall { call in
                if case let .respond(id, .success, nil) = call {
                    return id == transactionID
                }
                return false
            }
            await fake.waitForRecordedCall { call in
                if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                    return value == expectedIndication
                }
                return false
            }
            await server.waitUntilControlPointProcedureIdle()
        }
        #expect(await delegate.recordedValues.isEmpty)
    }

    @Test func shortCumulativeIndicatesInvalidParameter() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        let invalidBodies = [
            Data([0x01, 0x00, 0x00, 0x00]),
            Data([0x01]),
            Data([0x01, 0x00, 0x00, 0x00, 0x00, 0xFF]),
        ]

        for body in invalidBodies {
            await fake.emitWriteTransaction(
                PeripheralWriteTransaction(
                    id: UUID(),
                    requests: [
                        PeripheralWriteRequest(
                            centralID: writer,
                            serviceUUID: CSCS.serviceUUID,
                            characteristicUUID: CSCS.controlPointUUID,
                            offset: 0,
                            value: body,
                        ),
                    ],
                ),
            )
            await fake.waitForRecordedCall { call in
                if case let .updateValue(value, _, _, _) = call {
                    return value == CSCControlPointResponse(
                        requestOpcode: 0x01,
                        value: 0x03,
                        parameter: Data(),
                    ).encode()
                }
                return false
            }
            await server.waitUntilControlPointProcedureIdle()
        }
        #expect(await delegate.recordedValues.isEmpty)
    }

    @Test func responseCodeIndicatesOpCodeNotSupported() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: UUID(),
                requests: [
                    PeripheralWriteRequest(
                        centralID: writer,
                        serviceUUID: CSCS.serviceUUID,
                        characteristicUUID: CSCS.controlPointUUID,
                        offset: 0,
                        value: Data([0x10]),
                    ),
                ],
            ),
        )
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, _, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x10,
                    value: 0x02,
                    parameter: Data(),
                ).encode()
            }
            return false
        }
        #expect(await delegate.recordedValues.isEmpty)
    }

    @Test func otherCentralsSubscriptionDoesNotSatisfyWriter() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let centralA = UUID()
        let centralB = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: centralA)

        await fake.emitWriteTransaction(controlPointWrite(centralID: centralB))
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .error(0x81), nil) = call { return true }
            return false
        }
    }

    @Test func controlPointUnsubscribeReturns0x81() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)
        await fake.emitSubscription(
            .unsubscribed(
                centralID: writer,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
            ),
        )
        await server.waitForControlPointSubscribers([])

        await fake.emitWriteTransaction(controlPointWrite(centralID: writer))
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .error(0x81), nil) = call { return true }
            return false
        }
    }

    @Test func measurementUnsubscribeDoesNotClearControlPointSubscription() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await fake.emitSubscription(
            .subscribed(
                centralID: writer,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )
        await server.waitForMeasurementSubscribers([writer])
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitSubscription(
            .unsubscribed(
                centralID: writer,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )
        await server.waitForMeasurementSubscribers([])

        await fake.emitWriteTransaction(controlPointWrite(centralID: writer))
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .success, nil) = call { return true }
            return false
        }
    }

    @Test func emptyControlPointWriteWithoutSubscriptionReturns0x0D() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        let transactionID = UUID()
        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: transactionID,
                requests: [
                    PeripheralWriteRequest(
                        centralID: writer,
                        serviceUUID: CSCS.serviceUUID,
                        characteristicUUID: CSCS.controlPointUUID,
                        offset: 0,
                        value: Data(),
                    ),
                ],
            ),
        )
        await fake.waitForRecordedCall { call in
            if case let .respond(id, .error(0x0D), nil) = call {
                return id == transactionID
            }
            return false
        }
    }

    @Test func controlPointOffsetWithoutSubscriptionReturns0x07() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        let transactionID = UUID()
        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: transactionID,
                requests: [
                    PeripheralWriteRequest(
                        centralID: writer,
                        serviceUUID: CSCS.serviceUUID,
                        characteristicUUID: CSCS.controlPointUUID,
                        offset: 1,
                        value: Data([0x01, 0x78, 0x56, 0x34, 0x12]),
                    ),
                ],
            ),
        )
        await fake.waitForRecordedCall { call in
            if case let .respond(id, .error(0x07), nil) = call {
                return id == transactionID
            }
            return false
        }
    }

    @Test func controlPointOffsetReturnsInvalidOffset() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        let transactionID = UUID()
        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: transactionID,
                requests: [
                    PeripheralWriteRequest(
                        centralID: writer,
                        serviceUUID: CSCS.serviceUUID,
                        characteristicUUID: CSCS.controlPointUUID,
                        offset: 1,
                        value: Data([0x01, 0x78, 0x56, 0x34, 0x12]),
                    ),
                ],
            ),
        )
        await fake.waitForRecordedCall { call in
            if case let .respond(id, .error(0x07), nil) = call {
                return id == transactionID
            }
            return false
        }
        #expect(await delegate.recordedValues.isEmpty)
    }

    @Test func emptyControlPointWriteReturnsInvalidLength() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        let transactionID = UUID()
        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: transactionID,
                requests: [
                    PeripheralWriteRequest(
                        centralID: writer,
                        serviceUUID: CSCS.serviceUUID,
                        characteristicUUID: CSCS.controlPointUUID,
                        offset: 0,
                        value: Data(),
                    ),
                ],
            ),
        )
        await fake.waitForRecordedCall { call in
            if case let .respond(id, .error(0x0D), nil) = call {
                return id == transactionID
            }
            return false
        }
    }

    @Test func controlPointReadReturnsReadNotPermitted() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let requestID = UUID()
        await fake.emitRead(
            PeripheralReadRequest(
                id: requestID,
                centralID: UUID(),
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
                offset: 0,
            ),
        )
        await fake.waitForRecordedCall { call in
            if case let .respond(id, .error(0x02), nil) = call {
                return id == requestID
            }
            return false
        }
    }

    @Test func controlPointWriteOnForeignServiceReturnsWriteNotPermitted() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        let transactionID = UUID()
        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: transactionID,
                requests: [
                    PeripheralWriteRequest(
                        centralID: writer,
                        serviceUUID: UUID(),
                        characteristicUUID: CSCS.controlPointUUID,
                        offset: 0,
                        value: Data([0x01, 0x78, 0x56, 0x34, 0x12]),
                    ),
                ],
            ),
        )
        await fake.waitForRecordedCall { call in
            if case let .respond(id, .error(0x03), nil) = call {
                return id == transactionID
            }
            return false
        }
    }

    @Test func stopDuringParkedDelegateReturns() async throws {
        let delegate = ScriptedCumulativeDelegate()
        await delegate.armParkForNextCall()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(MultiPassEmptyWheelSequence(), setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(controlPointWrite(centralID: writer))
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .success, nil) = call { return true }
            return false
        }

        await server.stop()

        let cpUpdates = await fake.recordedCalls.compactMap { call -> Data? in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value
            }
            return nil
        }
        #expect(!cpUpdates.contains(CSCControlPointResponse(
            requestOpcode: 0x01,
            value: 0x01,
            parameter: Data(),
        ).encode()))
        #expect(!cpUpdates.contains(CSCControlPointResponse(
            requestOpcode: 0x01,
            value: 0x04,
            parameter: Data(),
        ).encode()))

        try await server.start(peripheral: fake)
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)
        let restartWriteID = UUID()
        await fake.emitWriteTransaction(controlPointWrite(centralID: writer, transactionID: restartWriteID))
        await fake.waitForRecordedCall { call in
            if case let .respond(id, .success, nil) = call {
                return id == restartWriteID
            }
            return false
        }
        await server.waitUntilControlPointProcedureIdle()

        let finalUpdates = await fake.recordedCalls.compactMap { call -> Data? in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value
            }
            return nil
        }
        #expect(finalUpdates.contains(CSCControlPointResponse(
            requestOpcode: 0x01,
            value: 0x01,
            parameter: Data(),
        ).encode()))
        #expect(!finalUpdates.contains(CSCControlPointResponse(
            requestOpcode: 0x01,
            value: 0x04,
            parameter: Data(),
        ).encode()))
    }
}

private struct EmptyWheelSequence: AsyncSequence, Sendable {
    typealias Element = WheelRevolution

    struct Iterator: AsyncIteratorProtocol, Sendable {
        func next() async throws -> WheelRevolution? { nil }
    }

    func makeAsyncIterator() -> Iterator { Iterator() }
}

private struct MultiPassEmptyWheelSequence: AsyncSequence, Sendable {
    typealias Element = WheelRevolution

    struct Iterator: AsyncIteratorProtocol, Sendable {
        func next() async throws -> WheelRevolution? { nil }
    }

    func makeAsyncIterator() -> Iterator { Iterator() }
}

private func makeYieldingWheelSequence() -> (
    sequence: YieldingWheelSequence,
    yield: @Sendable (WheelRevolution) async -> Void,
) {
    let sequence = YieldingWheelSequence()
    return (sequence, { revolution in
        await sequence.yield(revolution)
    })
}

private func makeYieldingCrankSequence() -> (
    sequence: YieldingCrankSequence,
    yield: @Sendable (CrankRevolution) async -> Void,
) {
    let sequence = YieldingCrankSequence()
    return (sequence, { revolution in
        await sequence.yield(revolution)
    })
}

private func subscribeMeasurement(
    fake: FakeBluetoothPeripheral,
    server: Server,
    centralID: UUID,
) async {
    await fake.emitSubscription(
        .subscribed(
            centralID: centralID,
            serviceUUID: CSCS.serviceUUID,
            characteristicUUID: CSCS.measurementUUID,
        ),
    )
    await server.waitForMeasurementSubscribers([centralID])
}

private func subscribeControlPoint(
    fake: FakeBluetoothPeripheral,
    server: Server,
    centralID: UUID,
) async {
    await fake.emitSubscription(
        .subscribed(
            centralID: centralID,
            serviceUUID: CSCS.serviceUUID,
            characteristicUUID: CSCS.controlPointUUID,
        ),
    )
    await server.waitForControlPointSubscribers([centralID])
}

private func controlPointWrite(
    centralID: UUID,
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
                value: Data([0x01, 0x78, 0x56, 0x34, 0x12]),
            ),
        ],
    )
}

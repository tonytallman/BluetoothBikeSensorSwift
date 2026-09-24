import CSCServer
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ServerWheelTests {
    @Test func wheelOnlyNotificationMatchesFixture() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (sequence, yield) = makeYieldingWheelSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(sequence, setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let centralID = UUID()
        await fake.emitSubscription(
            .subscribed(
                centralID: centralID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )
        await server.waitForMeasurementSubscribers([centralID])

        await yield(WheelRevolution(cumulativeRevolutions: 1000, lastEventTime: 1024))
        await server.waitUntilAcceptedMeasurementCount(1)

        let expected = CSCMeasurement(
            cumulativeWheelRevolutions: 1000,
            lastWheelEventTime: 1024,
        ).encode()!

        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, serviceUUID, characteristicUUID, .all) = call {
                return value == expected
                    && serviceUUID == CSCS.serviceUUID
                    && characteristicUUID == CSCS.measurementUUID
            }
            return false
        }

        let requestID = UUID()
        await fake.emitRead(
            PeripheralReadRequest(
                id: requestID,
                centralID: centralID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.featureUUID,
                offset: 0,
            ),
        )
        await fake.waitForRecordedCall { call in
            if case let .respond(id, .success, value) = call {
                return id == requestID && value == Data([0x01, 0x00])
            }
            return false
        }

        let calls = await fake.recordedCalls
        #expect(calls.contains { call in
            if case .add(server.service) = call { return true }
            return false
        })
    }

    @Test func secondSampleOnWheelAndCrankMatchesCombinedFixture() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (wheelSequence, yieldWheel) = makeYieldingWheelSequence()
        let (crankSequence, yieldCrank) = makeYieldingCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(wheelSequence, setCumulativeWheelRevolutions: delegate)
            .crankRevolutions(crankSequence)
            .build()
        try await server.start(peripheral: fake)

        let centralID = UUID()
        await fake.emitSubscription(
            .subscribed(
                centralID: centralID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )
        await server.waitForMeasurementSubscribers([centralID])

        await yieldWheel(WheelRevolution(cumulativeRevolutions: 100, lastEventTime: 1024))
        await server.waitUntilAcceptedMeasurementCount(1)

        await yieldCrank(CrankRevolution(cumulativeRevolutions: 80, lastEventTime: 2048))
        await server.waitUntilAcceptedMeasurementCount(2)

        let combined = CSCMeasurement(
            cumulativeWheelRevolutions: 100,
            lastWheelEventTime: 1024,
            cumulativeCrankRevolutions: 80,
            lastCrankEventTime: 2048,
        ).encode()!
        await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.contains { call in
                if case let .updateValue(value, _, _, _) = call {
                    return value == combined
                }
                return false
            }
        }

        await yieldWheel(WheelRevolution(cumulativeRevolutions: 101, lastEventTime: 1100))
        await server.waitUntilAcceptedMeasurementCount(3)

        let finalCombined = CSCMeasurement(
            cumulativeWheelRevolutions: 101,
            lastWheelEventTime: 1100,
            cumulativeCrankRevolutions: 80,
            lastCrankEventTime: 2048,
        ).encode()!
        await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.filter { call in
                if case let .updateValue(value, _, _, _) = call {
                    return value == finalCombined
                }
                return false
            }.count == 1
        }
    }

    @Test func invalidParameterLeavesAcceptedWheelInPlace() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (wheelSequence, yieldWheel) = makeYieldingWheelSequence()
        let (crankSequence, yieldCrank) = makeYieldingCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(wheelSequence, setCumulativeWheelRevolutions: delegate)
            .crankRevolutions(crankSequence)
            .build()
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

        await yieldWheel(WheelRevolution(cumulativeRevolutions: 50, lastEventTime: 1))
        await server.waitUntilAcceptedMeasurementCount(1)

        await fake.emitSubscription(
            .subscribed(
                centralID: writer,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
            ),
        )
        await server.waitForControlPointSubscribers([writer])

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
                        value: Data([0x01, 0x00, 0x00, 0x00]),
                    ),
                ],
            ),
        )

        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, characteristicUUID, _) = call,
               characteristicUUID == CSCS.controlPointUUID
            {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x01,
                    value: 0x03,
                    parameter: Data(),
                ).encode()
            }
            return false
        }
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
                if case let .updateValue(value, _, characteristicUUID, _) = call,
                   characteristicUUID == CSCS.measurementUUID
                {
                    return value == expected
                }
                return false
            }
        }
        #expect(await delegate.recordedValues.isEmpty)
    }

    @Test func successfulSetCumulativeDropsCachedWheel() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (wheelSequence, yieldWheel) = makeYieldingWheelSequence()
        let (crankSequence, yieldCrank) = makeYieldingCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(wheelSequence, setCumulativeWheelRevolutions: delegate)
            .crankRevolutions(crankSequence)
            .build()
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

        await yieldWheel(WheelRevolution(cumulativeRevolutions: 50, lastEventTime: 1))
        await server.waitUntilAcceptedMeasurementCount(1)
        await yieldCrank(CrankRevolution(cumulativeRevolutions: 10, lastEventTime: 2))
        await server.waitUntilAcceptedMeasurementCount(2)

        await fake.emitSubscription(
            .subscribed(
                centralID: writer,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
            ),
        )
        await server.waitForControlPointSubscribers([writer])

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
        await server.waitUntilControlPointProcedureIdle()

        await yieldCrank(CrankRevolution(cumulativeRevolutions: 11, lastEventTime: 3))
        await server.waitUntilAcceptedMeasurementCount(3)

        let crankOnly = CSCMeasurement(
            cumulativeCrankRevolutions: 11,
            lastCrankEventTime: 3,
        ).encode()!
        await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.contains { call in
                if case let .updateValue(value, _, characteristicUUID, _) = call,
                   characteristicUUID == CSCS.measurementUUID
                {
                    return value == crankOnly
                }
                return false
            }
        }

        await yieldWheel(WheelRevolution(cumulativeRevolutions: 0, lastEventTime: 4))
        await server.waitUntilAcceptedMeasurementCount(4)

        let combined = CSCMeasurement(
            cumulativeWheelRevolutions: 0,
            lastWheelEventTime: 4,
            cumulativeCrankRevolutions: 11,
            lastCrankEventTime: 3,
        ).encode()!
        await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.contains { call in
                if case let .updateValue(value, _, characteristicUUID, _) = call,
                   characteristicUUID == CSCS.measurementUUID
                {
                    return value == combined
                }
                return false
            }
        }
    }

    @Test func setCumulativeDiscardsUnsentWheelNotification() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (sequence, yield) = makeYieldingWheelSequence()
        let fake = FakeBluetoothPeripheral()
        await fake.setNextUpdateValueAccepted(false)
        let server = Server.wheelRevolutions(sequence, setCumulativeWheelRevolutions: delegate).build()
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

        await fake.emitSubscription(
            .subscribed(
                centralID: writer,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
            ),
        )
        await server.waitForControlPointSubscribers([writer])

        await yield(WheelRevolution(cumulativeRevolutions: 42, lastEventTime: 7))
        let wheelPayload = CSCMeasurement(
            cumulativeWheelRevolutions: 42,
            lastWheelEventTime: 7,
        ).encode()!
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, characteristicUUID, _) = call,
               characteristicUUID == CSCS.measurementUUID
            {
                return value == wheelPayload
            }
            return false
        }

        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: UUID(),
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

        let successIndication = CSCControlPointResponse(
            requestOpcode: 0x01,
            value: 0x01,
            parameter: Data(),
        ).encode()
        await fake.waitUntilRecordedCallsSatisfy { calls in
            let wheelCount = calls.filter { call in
                if case let .updateValue(value, _, characteristicUUID, _) = call,
                   characteristicUUID == CSCS.measurementUUID
                {
                    return value == wheelPayload
                }
                return false
            }.count
            let hasIndication = calls.contains { call in
                if case let .updateValue(value, _, characteristicUUID, _) = call,
                   characteristicUUID == CSCS.controlPointUUID
                {
                    return value == successIndication
                }
                return false
            }
            return wheelCount == 1 && hasIndication
        }

        await fake.setNextUpdateValueAccepted(true)
        await fake.emitReadyToUpdateSubscribers()
        await server.waitUntilControlPointProcedureIdle()
    }

    @Test func setCumulativeDiscardsUnsentCombinedCrankAndRequeuesCrankOnly() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (wheelSequence, yieldWheel) = makeYieldingWheelSequence()
        let (crankSequence, yieldCrank) = makeYieldingCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(wheelSequence, setCumulativeWheelRevolutions: delegate)
            .crankRevolutions(crankSequence)
            .build()
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

        await yieldWheel(WheelRevolution(cumulativeRevolutions: 50, lastEventTime: 1))
        await server.waitUntilAcceptedMeasurementCount(1)

        await fake.emitSubscription(
            .subscribed(
                centralID: writer,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
            ),
        )
        await server.waitForControlPointSubscribers([writer])

        await fake.setNextUpdateValueAccepted(false)

        let crank = CrankRevolution(cumulativeRevolutions: 10, lastEventTime: 2)
        await yieldCrank(crank)
        let combined = CSCMeasurement(
            cumulativeWheelRevolutions: 50,
            lastWheelEventTime: 1,
            cumulativeCrankRevolutions: 10,
            lastCrankEventTime: 2,
        ).encode()!
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, characteristicUUID, _) = call,
               characteristicUUID == CSCS.measurementUUID
            {
                return value == combined
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
            cumulativeCrankRevolutions: 10,
            lastCrankEventTime: 2,
        ).encode()!
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, characteristicUUID, _) = call,
               characteristicUUID == CSCS.measurementUUID
            {
                return value == crankOnly
            }
            return false
        }

        await fake.setNextUpdateValueAccepted(true)
        await fake.emitReadyToUpdateSubscribers()
        await server.waitUntilControlPointProcedureIdle()

        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, characteristicUUID, _) = call,
               characteristicUUID == CSCS.controlPointUUID
            {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x01,
                    value: 0x01,
                    parameter: Data(),
                ).encode()
            }
            return false
        }
    }

    @Test func measurementNotifiesWhileCumulativeDelegateParked() async throws {
        let delegate = ScriptedCumulativeDelegate()
        await delegate.armParkForNextCall()
        let (sequence, yield) = makeYieldingWheelSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(sequence, setCumulativeWheelRevolutions: delegate).build()
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

        await fake.emitSubscription(
            .subscribed(
                centralID: writer,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
            ),
        )
        await server.waitForControlPointSubscribers([writer])

        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: UUID(),
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
        await delegate.waitUntilRecordedCount(1)

        await yield(WheelRevolution(cumulativeRevolutions: 5, lastEventTime: 6))
        await fake.waitForRecordedCall { call in
            if case let .updateValue(_, _, characteristicUUID, _) = call {
                return characteristicUUID == CSCS.measurementUUID
            }
            return false
        }

        await delegate.release()
        await server.waitUntilControlPointProcedureIdle()

        let calls = await fake.recordedCalls
        let measurementIndex = calls.firstIndex { call in
            if case .updateValue(_, _, CSCS.measurementUUID, _) = call { return true }
            return false
        }
        let indicationIndex = calls.firstIndex { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x01,
                    value: 0x01,
                    parameter: Data(),
                ).encode()
            }
            return false
        }
        #expect(measurementIndex != nil)
        #expect(indicationIndex != nil)
        if let measurementIndex, let indicationIndex {
            #expect(measurementIndex < indicationIndex)
        }
    }

    @Test func zeroMaxAndDecreasePassThrough() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (sequence, yield) = makeYieldingWheelSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(sequence, setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let centralID = UUID()
        await fake.emitSubscription(
            .subscribed(
                centralID: centralID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )
        await server.waitForMeasurementSubscribers([centralID])

        let samples: [(UInt32, UInt16)] = [(0, 100), (UInt32.max, 200), (9, 300)]
        for (index, sample) in samples.enumerated() {
            await yield(WheelRevolution(cumulativeRevolutions: sample.0, lastEventTime: sample.1))
            await server.waitUntilAcceptedMeasurementCount(index + 1)
        }

        let expected = samples.map { sample in
            CSCMeasurement(
                cumulativeWheelRevolutions: sample.0,
                lastWheelEventTime: sample.1,
            ).encode()!
        }
        await fake.waitUntilRecordedCallsSatisfy { calls in
            let payloads = calls.compactMap { call -> Data? in
                if case let .updateValue(value, _, CSCS.measurementUUID, _) = call {
                    return value
                }
                return nil
            }
            return expected.allSatisfy { payloads.contains($0) }
        }
    }

    @Test func wheelSampleWithoutSubscribersIsDropped() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let wheelSequence = YieldingWheelSequence()
        let (crankSequence, yieldCrank) = makeYieldingCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(wheelSequence, setCumulativeWheelRevolutions: delegate)
            .crankRevolutions(crankSequence)
            .build()
        try await server.start(peripheral: fake)

        await wheelSequence.yield(WheelRevolution(cumulativeRevolutions: 1, lastEventTime: 2))
        await wheelSequence.waitUntilNextEntered(count: 2)

        let centralID = UUID()
        await fake.emitSubscription(
            .subscribed(
                centralID: centralID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )
        await server.waitForMeasurementSubscribers([centralID])

        await yieldCrank(CrankRevolution(cumulativeRevolutions: 3, lastEventTime: 4))
        let expected = CSCMeasurement(
            cumulativeCrankRevolutions: 3,
            lastCrankEventTime: 4,
        ).encode()!
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, characteristicUUID, _) = call,
               characteristicUUID == CSCS.measurementUUID
            {
                return value == expected
            }
            return false
        }
    }

    @Test func wheelBackpressureRetriesSamePayload() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (sequence, yield) = makeYieldingWheelSequence()
        let fake = FakeBluetoothPeripheral()
        await fake.setNextUpdateValueAccepted(false)
        let server = Server.wheelRevolutions(sequence, setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let centralID = UUID()
        await fake.emitSubscription(
            .subscribed(
                centralID: centralID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )
        await server.waitForMeasurementSubscribers([centralID])

        await yield(WheelRevolution(cumulativeRevolutions: 9, lastEventTime: 10))
        let expected = CSCMeasurement(
            cumulativeWheelRevolutions: 9,
            lastWheelEventTime: 10,
        ).encode()!

        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, _, _) = call {
                return value == expected
            }
            return false
        }

        await fake.setNextUpdateValueAccepted(true)
        await fake.emitReadyToUpdateSubscribers()

        await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.filter { call in
                if case let .updateValue(value, _, _, _) = call {
                    return value == expected
                }
                return false
            }.count == 2
        }
    }

    @Test func wheelSequenceEndStopsNotificationsOnly() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let sequence = ControlledWheelSequence(samples: [
            WheelRevolution(cumulativeRevolutions: 1, lastEventTime: 2),
        ])
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(sequence, setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let centralID = UUID()
        await fake.emitSubscription(
            .subscribed(
                centralID: centralID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )
        await server.waitForMeasurementSubscribers([centralID])
        await sequence.releaseSample()

        await sequence.waitForNextRequest(count: 1)

        let expected = CSCMeasurement(
            cumulativeWheelRevolutions: 1,
            lastWheelEventTime: 2,
        ).encode()!
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, characteristicUUID, _) = call,
               characteristicUUID == CSCS.measurementUUID
            {
                return value == expected
            }
            return false
        }

        #expect(await fake.isAdvertising)

        let requestID = UUID()
        await fake.emitRead(
            PeripheralReadRequest(
                id: requestID,
                centralID: centralID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.featureUUID,
                offset: 0,
            ),
        )
        await fake.waitForRecordedCall { call in
            if case let .respond(id, .success, value) = call {
                return id == requestID && value == Data([0x01, 0x00])
            }
            return false
        }
    }

    @Test func stopDuringAcceptedUpdateValueReturns() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (sequence, yield) = makeYieldingWheelSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(sequence, setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        let centralID = UUID()
        await fake.emitSubscription(
            .subscribed(
                centralID: centralID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )
        await server.waitForMeasurementSubscribers([centralID])

        await yield(WheelRevolution(cumulativeRevolutions: 1, lastEventTime: 2))
        await fake.waitForRecordedCall { call in
            if case .updateValue = call { return true }
            return false
        }

        await server.stop()
        #expect(await fake.isAdvertising == false)
    }

    @Test func stopCancelsWheelIteration() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let sequence = YieldingWheelSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(sequence, setCumulativeWheelRevolutions: delegate).build()
        try await server.start(peripheral: fake)

        await server.stop()
        #expect(await sequence.iterationWasCancelled())
    }

    @Test func wheelStaticLocationReadsCachedValueAndPublishesControlPoint() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate)
            .staticSensorLocation(.rearDropout)
            .build()
        try await server.start(peripheral: fake)

        let requestID = UUID()
        await fake.emitRead(
            PeripheralReadRequest(
                id: requestID,
                centralID: UUID(),
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.sensorLocationUUID,
                offset: 0,
            ),
        )
        await fake.waitForRecordedCall { call in
            if case let .respond(id, .success, value) = call {
                return id == requestID && value == Data([0x0A])
            }
            return false
        }

        let featureID = UUID()
        await fake.emitRead(
            PeripheralReadRequest(
                id: featureID,
                centralID: UUID(),
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.featureUUID,
                offset: 0,
            ),
        )
        await fake.waitForRecordedCall { call in
            if case let .respond(id, .success, value) = call {
                return id == featureID && value == Data([0x01, 0x00])
            }
            return false
        }

        #expect(server.service.characteristics.contains { $0.uuid == CSCS.controlPointUUID })
    }

    @Test func wheelCrankStaticStarts() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: delegate)
            .crankRevolutions(EmptyCrankSequence())
            .staticSensorLocation(.leftCrank)
            .build()
        try await server.start(peripheral: fake)

        let requestID = UUID()
        await fake.emitRead(
            PeripheralReadRequest(
                id: requestID,
                centralID: UUID(),
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.featureUUID,
                offset: 0,
            ),
        )
        await fake.waitForRecordedCall { call in
            if case let .respond(id, .success, value) = call {
                return id == requestID && value == Data([0x03, 0x00])
            }
            return false
        }
    }

    @Test func combinedServerCrankRolloverPassesThrough() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let (wheelSequence, yieldWheel) = makeYieldingWheelSequence()
        let (crankSequence, yieldCrank) = makeYieldingCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(wheelSequence, setCumulativeWheelRevolutions: delegate)
            .crankRevolutions(crankSequence)
            .build()
        try await server.start(peripheral: fake)

        let centralID = UUID()
        await fake.emitSubscription(
            .subscribed(
                centralID: centralID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )
        await server.waitForMeasurementSubscribers([centralID])

        await yieldWheel(WheelRevolution(cumulativeRevolutions: 100, lastEventTime: 1024))
        await server.waitUntilAcceptedMeasurementCount(1)

        await yieldCrank(CrankRevolution(cumulativeRevolutions: 0xFFFF, lastEventTime: 100))
        await server.waitUntilAcceptedMeasurementCount(2)
        let rollover = CSCMeasurement(
            cumulativeWheelRevolutions: 100,
            lastWheelEventTime: 1024,
            cumulativeCrankRevolutions: 0xFFFF,
            lastCrankEventTime: 100,
        ).encode()!
        await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.contains { call in
                if case let .updateValue(value, _, _, _) = call { return value == rollover }
                return false
            }
        }

        await yieldCrank(CrankRevolution(cumulativeRevolutions: 0x0000, lastEventTime: 200))
        await server.waitUntilAcceptedMeasurementCount(3)
        let wrapped = CSCMeasurement(
            cumulativeWheelRevolutions: 100,
            lastWheelEventTime: 1024,
            cumulativeCrankRevolutions: 0x0000,
            lastCrankEventTime: 200,
        ).encode()!
        await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.contains { call in
                if case let .updateValue(value, _, _, _) = call { return value == wrapped }
                return false
            }
        }
    }
}

private struct EmptyCrankSequence: AsyncSequence, Sendable {
    typealias Element = CrankRevolution

    struct Iterator: AsyncIteratorProtocol, Sendable {
        func next() async throws -> CrankRevolution? { nil }
    }

    func makeAsyncIterator() -> Iterator { Iterator() }
}

private struct EmptyWheelSequence: AsyncSequence, Sendable {
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

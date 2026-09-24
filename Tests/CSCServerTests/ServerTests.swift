import CSCServer
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ServerTests {
    @Test func crankOnlyStartupRecordsAddAndAdvertise() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(EmptyCrankSequence()).build()

        try await server.start(peripheral: fake)

        let calls = await fake.recordedCalls
        #expect(calls == [
            .add(server.service),
            .startAdvertising(Advertisement(localName: nil, serviceUUIDs: [CSCS.serviceUUID])),
        ])
        #expect(await fake.isAdvertising)
    }

    @Test func startupProceedsAfterUnknownBecomesPoweredOn() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .unknown)
        let server = Server.crankRevolutions(EmptyCrankSequence()).build()

        let startTask = Task {
            try await server.start(peripheral: fake)
        }

        await fake.waitForStateUpdatesSubscriber()
        await fake.setState(.poweredOn)
        try await startTask.value

        let calls = await fake.recordedCalls
        #expect(calls.contains { call in
            if case .startAdvertising = call { return true }
            return false
        })
    }

    @Test func poweredOffThrowsNotPoweredOn() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOff)
        let server = Server.crankRevolutions(EmptyCrankSequence()).build()

        await #expect(throws: ServerError.notPoweredOn) {
            try await server.start(peripheral: fake)
        }
        #expect(await fake.recordedCalls.isEmpty)
    }

    @Test func failedAddThrowsPublishFailed() async throws {
        let fake = FakeBluetoothPeripheral()
        await fake.failNextAdd()
        let server = Server.crankRevolutions(EmptyCrankSequence()).build()

        await #expect(throws: ServerError.publishFailed(reason: "Test failure")) {
            try await server.start(peripheral: fake)
        }
    }

    @Test func failedAdvertiseThrowsAdvertisingFailedAndRemovesService() async throws {
        let fake = FakeBluetoothPeripheral()
        await fake.failNextAdvertise()
        let server = Server.crankRevolutions(EmptyCrankSequence()).build()

        await #expect(throws: ServerError.advertisingFailed(reason: "Test failure")) {
            try await server.start(peripheral: fake)
        }

        await fake.waitUntilEventSubscriberCount(0)

        let calls = await fake.recordedCalls
        #expect(calls.contains { call in
            if case .add = call { return true }
            return false
        })
        #expect(calls.contains { call in
            if case .removeService = call { return true }
            return false
        })
        #expect(await fake.isAdvertising == false)
    }

    @Test func wheelStartupRecordsAddAndAdvertise() async throws {
        let cumulative = CumulativeSpy()
        let server = Server.wheelRevolutions(
            EmptyWheelSequence(),
            setCumulativeWheelRevolutions: cumulative,
        ).build()
        let fake = FakeBluetoothPeripheral()

        try await server.start(peripheral: fake)

        let calls = await fake.recordedCalls
        #expect(calls == [
            .add(server.service),
            .startAdvertising(Advertisement(localName: nil, serviceUUIDs: [CSCS.serviceUUID])),
        ])
        #expect(await fake.isAdvertising)
    }

    @Test func crankPlusMultipleStartAddsAndAdvertises() async throws {
        let locations = LocationsSpy(supported: [.leftCrank], current: .leftCrank)
        let server = Server.crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()

        try await server.start(peripheral: fake)

        let calls = await fake.recordedCalls
        #expect(calls.first == .add(server.service))
        #expect(calls.contains(.startAdvertising(Advertisement(localName: nil, serviceUUIDs: [CSCS.serviceUUID]))))
        #expect(await fake.isAdvertising)
    }

    @Test func wheelPlusMultipleStartAddsAndAdvertises() async throws {
        let cumulative = CumulativeSpy()
        let locations = LocationsSpy(supported: [.leftCrank], current: .leftCrank)
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: cumulative)
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()

        try await server.start(peripheral: fake)

        let calls = await fake.recordedCalls
        #expect(calls.first == .add(server.service))
        #expect(calls.contains(.startAdvertising(Advertisement(localName: nil, serviceUUIDs: [CSCS.serviceUUID]))))
        #expect(await fake.isAdvertising)
    }

    @Test func wheelCrankMultipleStartAddsAndAdvertises() async throws {
        let cumulative = CumulativeSpy()
        let locations = LocationsSpy(supported: [.leftCrank], current: .leftCrank)
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: cumulative)
            .crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()

        try await server.start(peripheral: fake)

        let calls = await fake.recordedCalls
        #expect(calls.first == .add(server.service))
        #expect(calls.contains(.startAdvertising(Advertisement(localName: nil, serviceUUIDs: [CSCS.serviceUUID]))))
        #expect(await fake.isAdvertising)
    }

    @Test func crankOnlyWriteToControlPointUUIDIsWriteNotPermitted() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(EmptyCrankSequence()).build()
        try await server.start(peripheral: fake)

        let validSetCumulative = PeripheralWriteTransaction(
            id: UUID(),
            requests: [
                PeripheralWriteRequest(
                    centralID: UUID(),
                    serviceUUID: CSCS.serviceUUID,
                    characteristicUUID: CSCS.controlPointUUID,
                    offset: 0,
                    value: Data([0x01, 0x78, 0x56, 0x34, 0x12]),
                ),
            ],
        )
        let offsetWrite = PeripheralWriteTransaction(
            id: UUID(),
            requests: [
                PeripheralWriteRequest(
                    centralID: UUID(),
                    serviceUUID: CSCS.serviceUUID,
                    characteristicUUID: CSCS.controlPointUUID,
                    offset: 1,
                    value: Data([0x01, 0x78, 0x56, 0x34, 0x12]),
                ),
            ],
        )
        let emptyWrite = PeripheralWriteTransaction(
            id: UUID(),
            requests: [
                PeripheralWriteRequest(
                    centralID: UUID(),
                    serviceUUID: CSCS.serviceUUID,
                    characteristicUUID: CSCS.controlPointUUID,
                    offset: 0,
                    value: Data(),
                ),
            ],
        )

        for transaction in [validSetCumulative, offsetWrite, emptyWrite] {
            await fake.emitWriteTransaction(transaction)
            await fake.waitForRecordedCall { call in
                if case let .respond(id, .error(0x03), nil) = call {
                    return id == transaction.id
                }
                return false
            }
        }

        let updateCalls = await fake.recordedCalls.filter { call in
            if case .updateValue = call { return true }
            return false
        }
        #expect(updateCalls.isEmpty)
    }

    @Test func wheelServerFeatureWriteReturnsWriteNotPermitted() async throws {
        let cumulative = CumulativeSpy()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(
            EmptyWheelSequence(),
            setCumulativeWheelRevolutions: cumulative,
        ).build()
        try await server.start(peripheral: fake)

        let transactionID = UUID()
        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: transactionID,
                requests: [
                    PeripheralWriteRequest(
                        centralID: UUID(),
                        serviceUUID: CSCS.serviceUUID,
                        characteristicUUID: CSCS.featureUUID,
                        offset: 0,
                        value: Data([0x01]),
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

        let updateCalls = await fake.recordedCalls.filter { call in
            if case .updateValue = call { return true }
            return false
        }
        #expect(updateCalls.isEmpty)
    }

    @Test func secondStartThrowsAlreadyStarted() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(EmptyCrankSequence()).build()

        try await server.start(peripheral: fake)

        await #expect(throws: ServerError.alreadyStarted) {
            try await server.start(peripheral: fake)
        }
    }

    @Test func cancellingStartWhileWaitingForPowerThrowsCancellationError() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .unknown)
        let server = Server.crankRevolutions(EmptyCrankSequence()).build()

        let startTask = Task {
            try await server.start(peripheral: fake)
        }

        await fake.waitForStateUpdatesSubscriber()
        startTask.cancel()

        await #expect(throws: CancellationError.self) {
            try await startTask.value
        }
        #expect(await fake.recordedCalls.isEmpty)
    }

    @Test func readFeatureReturnsCrankFeatureBytes() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(EmptyCrankSequence()).build()
        try await server.start(peripheral: fake)

        let requestID = UUID()
        let centralID = UUID()
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
                return id == requestID && value == Data([0x02, 0x00])
            }
            return false
        }
    }

    @Test func readFeatureAtOffsetOneReturnsSecondByte() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(EmptyCrankSequence()).build()
        try await server.start(peripheral: fake)

        let requestID = UUID()
        await fake.emitRead(
            PeripheralReadRequest(
                id: requestID,
                centralID: UUID(),
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.featureUUID,
                offset: 1,
            ),
        )

        await fake.waitForRecordedCall { call in
            if case let .respond(id, .success, value) = call {
                return id == requestID && value == Data([0x00])
            }
            return false
        }
    }

    @Test func readFeaturePastEndReturnsInvalidOffset() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(EmptyCrankSequence()).build()
        try await server.start(peripheral: fake)

        let requestID = UUID()
        await fake.emitRead(
            PeripheralReadRequest(
                id: requestID,
                centralID: UUID(),
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.featureUUID,
                offset: 3,
            ),
        )

        await fake.waitForRecordedCall { call in
            if case let .respond(id, .error(0x07), nil) = call {
                return id == requestID
            }
            return false
        }
    }

    @Test func staticLocationReadsLeftCrank() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(EmptyCrankSequence())
            .staticSensorLocation(.leftCrank)
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
                return id == requestID && value == Data([0x05])
            }
            return false
        }
    }

    @Test func absentLocationCharacteristicReadReturnsAttributeNotFound() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(EmptyCrankSequence()).build()
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
            if case let .respond(id, .error(0x0A), nil) = call {
                return id == requestID
            }
            return false
        }
    }

    @Test func measurementReadReturnsReadNotPermitted() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(EmptyCrankSequence()).build()
        try await server.start(peripheral: fake)

        let requestID = UUID()
        await fake.emitRead(
            PeripheralReadRequest(
                id: requestID,
                centralID: UUID(),
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
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

    @Test func writeReturnsWriteNotPermitted() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(EmptyCrankSequence()).build()
        try await server.start(peripheral: fake)

        let requestID = UUID()
        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: requestID,
                requests: [
                    PeripheralWriteRequest(
                        centralID: UUID(),
                        serviceUUID: CSCS.serviceUUID,
                        characteristicUUID: CSCS.featureUUID,
                        offset: 0,
                        value: Data([0x01]),
                    ),
                ],
            ),
        )

        await fake.waitForRecordedCall { call in
            if case let .respond(id, .error(0x03), nil) = call {
                return id == requestID
            }
            return false
        }
    }

    @Test func subscribedCentralReceivesCrankNotification() async throws {
        let (sequence, yield) = makeYieldingCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(sequence).build()
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

        let revolution = CrankRevolution(cumulativeRevolutions: 0x1234, lastEventTime: 0xABCD)
        await yield(revolution)

        let expected = CSCMeasurement(
            cumulativeCrankRevolutions: 0x1234,
            lastCrankEventTime: 0xABCD,
        ).encode()!

        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, serviceUUID, characteristicUUID, .all) = call {
                return value == expected
                    && serviceUUID == CSCS.serviceUUID
                    && characteristicUUID == CSCS.measurementUUID
            }
            return false
        }
        #expect(expected == Data([0x02, 0x34, 0x12, 0xCD, 0xAB]))
    }

    @Test func rolloverPassesThroughUnchanged() async throws {
        let (sequence, yield) = makeYieldingCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(sequence).build()
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

        await yield(CrankRevolution(cumulativeRevolutions: 0xFFFF, lastEventTime: 100))

        let rolloverSample = CSCMeasurement(
            cumulativeCrankRevolutions: 0xFFFF,
            lastCrankEventTime: 100,
        ).encode()!
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, _, _) = call {
                return value == rolloverSample
            }
            return false
        }

        await yield(CrankRevolution(cumulativeRevolutions: 0x0000, lastEventTime: 200))

        await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.filter { call in
                if case let .updateValue(value, _, _, _) = call {
                    return value == CSCMeasurement(
                        cumulativeCrankRevolutions: 0x0000,
                        lastCrankEventTime: 200,
                    ).encode()
                }
                return false
            }.count == 1
        }
    }

    @Test func crankSequenceEndingStopsNotificationsOnly() async throws {
        let sequence = ControlledCrankSequence(samples: [
            CrankRevolution(cumulativeRevolutions: 1, lastEventTime: 2),
        ])
        let fake = FakeBluetoothPeripheral()
        await fake.holdNextAdvertise()
        let server = Server.crankRevolutions(sequence).build()

        let startTask = Task {
            try await server.start(peripheral: fake)
        }

        await fake.waitForRecordedCall { call in
            if case .add = call { return true }
            return false
        }

        let centralID = UUID()
        await fake.emitSubscription(
            .subscribed(
                centralID: centralID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )

        await fake.releaseAdvertise()
        try await startTask.value

        await sequence.waitForNextRequest(count: 1)

        await fake.waitForRecordedCall { call in
            if case .updateValue = call { return true }
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
                return id == requestID && value == Data([0x02, 0x00])
            }
            return false
        }
    }

    @Test func sampleWithoutSubscribersIsDropped() async throws {
        let sequence = ControlledCrankSequence(samples: [
            CrankRevolution(cumulativeRevolutions: 1, lastEventTime: 2),
            CrankRevolution(cumulativeRevolutions: 3, lastEventTime: 4),
        ])
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(sequence).build()
        try await server.start(peripheral: fake)

        await sequence.waitForNextRequest(count: 2)

        let updateCalls = await fake.recordedCalls.filter { call in
            if case .updateValue = call { return true }
            return false
        }
        #expect(updateCalls.isEmpty)
    }

    @Test func sampleAfterUnsubscribeIsDropped() async throws {
        let (sequence, yield) = makeYieldingCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(sequence).build()
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

        await yield(CrankRevolution(cumulativeRevolutions: 1, lastEventTime: 2))

        await fake.waitForRecordedCall { call in
            if case .updateValue = call { return true }
            return false
        }

        await fake.emitSubscription(
            .unsubscribed(
                centralID: centralID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )
        await server.waitForMeasurementSubscribers([])

        await yield(CrankRevolution(cumulativeRevolutions: 3, lastEventTime: 4))

        let updateCount = await fake.recordedCalls.filter { call in
            if case .updateValue = call { return true }
            return false
        }.count
        #expect(updateCount == 1)
    }

    @Test func backpressureRetriesSamePayloadAfterReady() async throws {
        let (sequence, yield) = makeYieldingCrankSequence()
        let fake = FakeBluetoothPeripheral()
        await fake.setNextUpdateValueAccepted(false)
        let server = Server.crankRevolutions(sequence).build()
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

        let revolution = CrankRevolution(cumulativeRevolutions: 9, lastEventTime: 10)
        await yield(revolution)
        let expected = CSCMeasurement(
            cumulativeCrankRevolutions: 9,
            lastCrankEventTime: 10,
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

    @Test func stopDuringBackpressureReturnsAndStopsAdvertising() async throws {
        let (sequence, yield) = makeYieldingCrankSequence()
        let fake = FakeBluetoothPeripheral()
        await fake.setNextUpdateValueAccepted(false)
        let server = Server.crankRevolutions(sequence).build()
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

        await yield(CrankRevolution(cumulativeRevolutions: 1, lastEventTime: 2))

        await fake.waitForRecordedCall { call in
            if case .updateValue = call { return true }
            return false
        }

        await server.stop()

        #expect(await fake.isAdvertising == false)
    }

    @Test func stopDuringAdvertiseHoldCleansUpAndLaterStartSucceeds() async throws {
        let fake = FakeBluetoothPeripheral()
        await fake.holdNextAdvertise()
        let server = Server.crankRevolutions(EmptyCrankSequence()).build()

        let startTask = Task {
            try await server.start(peripheral: fake)
        }

        await fake.waitUntilAdvertiseHeld()

        let stopTask = Task {
            await server.stop()
        }

        await fake.waitForRecordedCall { call in
            if case .removeService = call { return true }
            return false
        }
        await fake.releaseAdvertise()

        await stopTask.value

        await #expect(throws: CancellationError.self) {
            try await startTask.value
        }

        #expect(await fake.isAdvertising == false)

        try await server.start(peripheral: fake)
        #expect(await fake.isAdvertising)
    }

    @Test func waitForMeasurementSubscribersReturnsWhenStopRuns() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(EmptyCrankSequence()).build()
        try await server.start(peripheral: fake)

        let missingID = UUID()
        let waiterTask = Task {
            await server.waitForMeasurementSubscribers([missingID])
        }

        await server.waitUntilMeasurementSubscriberWaiterParked()

        await server.stop()
        await waiterTask.value
    }

    @Test func stopRecordsStopAdvertisingAndRemoveService() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(EmptyCrankSequence()).build()
        try await server.start(peripheral: fake)

        await server.stop()

        let calls = await fake.recordedCalls
        #expect(calls.contains { call in
            if case .stopAdvertising = call { return true }
            return false
        })
        #expect(calls.contains { call in
            if case .removeService(uuid: CSCS.serviceUUID) = call { return true }
            return false
        })
        #expect(await fake.isAdvertising == false)
    }

    @Test func stopBeforeStartIsNoOp() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(EmptyCrankSequence()).build()

        await server.stop()

        #expect(await fake.recordedCalls.isEmpty)
    }

    @Test func stopIsIdempotent() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(EmptyCrankSequence()).build()
        try await server.start(peripheral: fake)

        await server.stop()
        await server.stop()

        let stopCount = await fake.recordedCalls.filter { call in
            if case .stopAdvertising = call { return true }
            return false
        }.count
        #expect(stopCount == 1)
    }

    @Test func stopDuringStartupThrowsCancellationError() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .unknown)
        let server = Server.crankRevolutions(EmptyCrankSequence()).build()

        let startTask = Task {
            try await server.start(peripheral: fake)
        }

        await fake.waitForStateUpdatesSubscriber()
        let stopTask = Task {
            await server.stop()
        }

        await stopTask.value

        await #expect(throws: CancellationError.self) {
            try await startTask.value
        }
    }

    @Test func restartRepublishesServiceAndCanNotify() async throws {
        let (sequence, yield) = makeYieldingCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(sequence).build()

        try await server.start(peripheral: fake)
        await server.stop()
        try await server.start(peripheral: fake)

        let addCount = await fake.recordedCalls.filter { call in
            if case .add = call { return true }
            return false
        }.count
        let advertiseCount = await fake.recordedCalls.filter { call in
            if case .startAdvertising = call { return true }
            return false
        }.count
        #expect(addCount == 2)
        #expect(advertiseCount == 2)

        let centralID = UUID()
        await fake.emitSubscription(
            .subscribed(
                centralID: centralID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )
        await server.waitForMeasurementSubscribers([centralID])

        await yield(CrankRevolution(cumulativeRevolutions: 7, lastEventTime: 8))

        await fake.waitForRecordedCall { call in
            if case .updateValue = call { return true }
            return false
        }
    }

    @Test func stopCancelsCrankIteration() async throws {
        let sequence = YieldingCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(sequence).build()
        try await server.start(peripheral: fake)

        await server.stop()

        #expect(await sequence.iterationWasCancelled())
    }
}

private struct EmptyCrankSequence: AsyncSequence, Sendable {
    typealias Element = CrankRevolution

    struct Iterator: AsyncIteratorProtocol, Sendable {
        func next() async throws -> CrankRevolution? {
            nil
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator()
    }
}

private struct EmptyWheelSequence: AsyncSequence, Sendable {
    typealias Element = WheelRevolution

    struct Iterator: AsyncIteratorProtocol, Sendable {
        func next() async throws -> WheelRevolution? {
            nil
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator()
    }
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

private final class CumulativeSpy: SetCumulativeWheelRevolutions, @unchecked Sendable {
    func setCumulativeWheelRevolutions(_ cumulativeRevolutions: UInt32) async throws {}
}

private final class LocationsSpy: MultipleSensorLocationsDelegate, @unchecked Sendable {
    var supported: [SensorLocationKind]
    var current: SensorLocationKind

    init(supported: [SensorLocationKind], current: SensorLocationKind) {
        self.supported = supported
        self.current = current
    }

    func update(_ location: SensorLocationKind) async throws {
        current = location
    }
}

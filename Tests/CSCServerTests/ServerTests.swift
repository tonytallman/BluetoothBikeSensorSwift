import CSCServer
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ServerTests {
    private let centralID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private func crankServer(_ sequence: GatedCrankSequence = GatedCrankSequence()) -> Server {
        Server.crankRevolutions(GatedAsyncSequence(sequence: sequence)).build()
    }

    // MARK: - Feature and location reads

    @Test func crankFeatureRead() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let server = crankServer()

        let startTask = Task { try await server.start(peripheral: fake) }
        try await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.contains { if case .add = $0 { return true } else { return false } }
                && calls.contains {
                    if case .startAdvertising = $0 { return true } else { return false }
                }
        }

        try await emitFeatureRead(fake: fake, server: server, offset: 0, expected: Data([0x02, 0x00]))
        let decoded = CSCFeature.decode(Data([0x02, 0x00]))
        #expect(decoded == .crankRevolutionData)

        await server.stop()
        _ = try await startTask.value
    }

    @Test func staticLocationRead() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let server = Server.crankRevolutions(GatedAsyncSequence(sequence: GatedCrankSequence()))
            .staticSensorLocation(.leftCrank)
            .build()

        let startTask = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)

        try await emitRead(
            fake: fake,
            server: server,
            characteristicUUID: CSCS.sensorLocationUUID,
            offset: 0,
            expectedResult: .success,
            expectedValue: Data([0x05]),
        )

        await server.stop()
        _ = try await startTask.value
    }

    @Test func absentStaticLocationCharacteristic() async throws {
        let server = crankServer()
        #expect(!server.service.characteristics.contains { $0.uuid == CSCS.sensorLocationUUID })
    }

    @Test func featureReadOffsets() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let server = crankServer()
        let startTask = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)

        try await emitFeatureRead(fake: fake, server: server, offset: 1, expected: Data([0x00]))
        try await emitFeatureRead(fake: fake, server: server, offset: 2, expected: Data())
        try await emitRead(
            fake: fake,
            server: server,
            characteristicUUID: CSCS.featureUUID,
            offset: 3,
            expectedResult: .error(code: 0x07),
            expectedValue: nil,
        )
        try await emitRead(
            fake: fake,
            server: server,
            characteristicUUID: CSCS.featureUUID,
            offset: -1,
            expectedResult: .error(code: 0x07),
            expectedValue: nil,
        )

        await server.stop()
        _ = try await startTask.value
    }

    @Test func staticLocationReadOffsets() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let server = Server.crankRevolutions(GatedAsyncSequence(sequence: GatedCrankSequence()))
            .staticSensorLocation(.leftCrank)
            .build()
        let startTask = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)

        try await emitRead(
            fake: fake,
            server: server,
            characteristicUUID: CSCS.sensorLocationUUID,
            offset: 1,
            expectedResult: .success,
            expectedValue: Data(),
        )
        try await emitRead(
            fake: fake,
            server: server,
            characteristicUUID: CSCS.sensorLocationUUID,
            offset: 2,
            expectedResult: .error(code: 0x07),
            expectedValue: nil,
        )

        await server.stop()
        _ = try await startTask.value
    }

    @Test func measurementReadNotPermitted() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let server = crankServer()
        let startTask = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)

        try await emitRead(
            fake: fake,
            server: server,
            characteristicUUID: CSCS.measurementUUID,
            offset: 0,
            expectedResult: .error(code: 0x02),
            expectedValue: nil,
        )

        await server.stop()
        _ = try await startTask.value
    }

    @Test func crankOnlyWriteRejected() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let server = crankServer()
        let startTask = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)

        let transactionID = UUID()
        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: transactionID,
                requests: [
                    PeripheralWriteRequest(
                        centralID: centralID,
                        serviceUUID: CSCS.serviceUUID,
                        characteristicUUID: CSCS.measurementUUID,
                        offset: 0,
                        value: Data([0x01]),
                    ),
                ],
            ),
        )
        try await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.contains {
                if case let .respond(id, result, value) = $0 {
                    return id == transactionID && result == .error(code: 0x03) && value == nil
                }
                return false
            }
        }

        await server.stop()
        _ = try await startTask.value
    }

    // MARK: - Notifications

    @Test func gatedSequencePullCompletesInIsolation() async throws {
        let sequence = GatedCrankSequence()
        let gated = GatedAsyncSequence(sequence: sequence)
        let pullTask = Task {
            let iterator = gated.makeAsyncIterator()
            _ = try await iterator.next()
        }
        try await sequence.waitUntilIteratorExists()
        try await sequence.waitUntilSuspended()
        sequence.release(CrankRevolution(cumulativeRevolutions: 1, lastEventTime: 1))
        try await sequence.waitUntilPullCompleted(count: 1)
        _ = try await pullTask.value
    }

    @Test func subscriberStreamReceivesCentral() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let server = crankServer()
        let startTask = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)
        let stream = await server.measurementSubscriberUpdates()
        await fake.emitSubscription(
            .subscribed(centralID: centralID, serviceUUID: CSCS.serviceUUID, characteristicUUID: CSCS.measurementUUID),
        )
        try await waitForSubscriber(stream: stream, centralID: centralID)
        await server.stop()
        _ = try await startTask.value
    }

    @Test func notificationsMatchCSCWire() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let sequence = GatedCrankSequence()
        let server = crankServer(sequence)

        let startTask = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)

        let subscriberStream = await server.measurementSubscriberUpdates()
        try await subscribeAndWait(fake: fake, server: server, stream: subscriberStream)

        let expected = CSCMeasurement(
            cumulativeCrankRevolutions: 500,
            lastCrankEventTime: 2048,
        ).encode()!

        sequence.release(CrankRevolution(cumulativeRevolutions: 500, lastEventTime: 2048))

        try await fake.waitUntilRecordedCallsSatisfy { calls in
            hasUpdateValue(calls, value: expected)
        }

        await server.stop()
        _ = try await startTask.value
    }

    @Test func uint16Rollover() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let sequence = GatedCrankSequence()
        let server = crankServer(sequence)

        let startTask = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)

        let subscriberStream = await server.measurementSubscriberUpdates()
        try await subscribeAndWait(fake: fake, server: server, stream: subscriberStream)

        sequence.release(CrankRevolution(cumulativeRevolutions: .max, lastEventTime: 1))
        try await sequence.waitUntilPullCompleted(count: 1)
        let firstExpected = CSCMeasurement(
            cumulativeCrankRevolutions: .max,
            lastCrankEventTime: 1,
        ).encode()!
        try await fake.waitUntilRecordedCallsSatisfy { calls in
            hasUpdateValue(calls, value: firstExpected)
        }

        sequence.release(CrankRevolution(cumulativeRevolutions: 0, lastEventTime: 2))
        let secondExpected = CSCMeasurement(
            cumulativeCrankRevolutions: 0,
            lastCrankEventTime: 2,
        ).encode()!
        try await fake.waitUntilRecordedCallsSatisfy { calls in
            updateValueCalls(calls).filter { call in
                if case let .updateValue(value, _, _, _) = call { return value == secondExpected }
                return false
            }.count == 1
        }

        await server.stop()
        _ = try await startTask.value
    }

    // MARK: - Stop and cancel

    @Test func stoppingEndsNotifications() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let sequence = GatedCrankSequence()
        let server = crankServer(sequence)

        let startTask = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)

        let subscriberStream = await server.measurementSubscriberUpdates()
        try await subscribeAndWait(fake: fake, server: server, stream: subscriberStream)
        sequence.release(CrankRevolution(cumulativeRevolutions: 1, lastEventTime: 1))

        try await fake.waitUntilRecordedCallsSatisfy { calls in
            updateValueCalls(calls).count == 1
        }
        try await sequence.waitUntilSuspended()

        await server.stop()
        _ = try await startTask.value
        #expect(await fake.isAdvertising == false)
        #expect(await recordedContains(fake, .stopAdvertising))
        #expect(await recordedContains(fake, .removeService(uuid: CSCS.serviceUUID)))

        sequence.release(CrankRevolution(cumulativeRevolutions: 2, lastEventTime: 2))
        try await sequence.waitUntilPullCompleted(count: 2)
        #expect(updateValueCalls(await fake.recordedCalls).count == 1)
    }

    @Test func cancellingEndsNotifications() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let sequence = GatedCrankSequence()
        let server = crankServer(sequence)

        let startTask = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)

        let subscriberStream = await server.measurementSubscriberUpdates()
        try await subscribeAndWait(fake: fake, server: server, stream: subscriberStream)
        sequence.release(CrankRevolution(cumulativeRevolutions: 1, lastEventTime: 1))
        try await fake.waitUntilRecordedCallsSatisfy { calls in updateValueCalls(calls).count == 1 }
        try await sequence.waitUntilSuspended()

        startTask.cancel()
        await #expect(throws: CancellationError.self) { try await startTask.value }
        #expect(await fake.isAdvertising == false)

        sequence.release(CrankRevolution(cumulativeRevolutions: 2, lastEventTime: 2))
        try await sequence.waitUntilPullCompleted(count: 2)
        #expect(updateValueCalls(await fake.recordedCalls).count == 1)
    }

    // MARK: - Unsupported and concurrency

    @Test func unsupportedConfigurations() async throws {
        let cumulative = CumulativeSpy()
        let locations = LocationsSpy(supported: [.leftCrank], current: .leftCrank)
        let crank = GatedAsyncSequence(sequence: GatedCrankSequence())
        let wheel = EmptyWheelSequence()

        let servers: [Server] = [
            Server.wheelRevolutions(wheel, setCumulativeWheelRevolutions: cumulative).build(),
            Server.wheelRevolutions(wheel, setCumulativeWheelRevolutions: cumulative)
                .staticSensorLocation(.leftCrank).build(),
            Server.wheelRevolutions(wheel, setCumulativeWheelRevolutions: cumulative)
                .crankRevolutions(crank).build(),
            Server.wheelRevolutions(wheel, setCumulativeWheelRevolutions: cumulative)
                .crankRevolutions(crank).staticSensorLocation(.leftCrank).build(),
            Server.crankRevolutions(crank).multipleSensorLocations(locations).build(),
            Server.wheelRevolutions(wheel, setCumulativeWheelRevolutions: cumulative)
                .multipleSensorLocations(locations).build(),
            Server.wheelRevolutions(wheel, setCumulativeWheelRevolutions: cumulative)
                .crankRevolutions(crank).multipleSensorLocations(locations).build(),
        ]

        for server in servers {
            let fake = FakeBluetoothPeripheral()
            await #expect(throws: ServerError.unsupportedConfiguration) {
                try await server.start(peripheral: fake)
            }
            #expect(await fake.recordedCalls.isEmpty)
            #expect(cumulative.setCount == 0)
            #expect(locations.updateCount == 0)
        }
    }

    @Test func secondStartThrowsAlreadyStarted() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let sequence = GatedCrankSequence()
        let server = crankServer(sequence)

        let first = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)
        try await sequence.waitUntilSuspended()

        await #expect(throws: ServerError.alreadyStarted) {
            try await server.start(peripheral: fake)
        }
        #expect(await fake.isAdvertising)

        await server.stop()
        _ = try await first.value
    }

    @Test func stopBeforeStartIsIdempotent() async throws {
        let server = crankServer()
        await server.stop()
        await server.stop()
    }

    @Test func restartAfterStop() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let sequence = GatedCrankSequence()
        let server = crankServer(sequence)

        let first = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)
        await server.stop()
        _ = try await first.value

        let second = Task { try await server.start(peripheral: fake) }
        try await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.filter {
                if case .startAdvertising = $0 { return true } else { return false }
            }.count >= 2
        }
        await server.stop()
        _ = try await second.value
    }

    // MARK: - Restart with stale pull

    @Test func restartDropsStalePull() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let sequence = GatedCrankSequence()
        let server = crankServer(sequence)

        let session1 = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)
        try await sequence.waitUntilSuspended()
        #expect(updateValueCalls(await fake.recordedCalls).isEmpty)
        #expect(sequence.overlapped == false)

        await server.stop()
        _ = try await session1.value

        let session2 = Task { try await server.start(peripheral: fake) }
        try await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.filter { if case .startAdvertising = $0 { return true } else { return false } }.count >= 2
        }
        #expect(sequence.overlapped == false)

        let subscriberStream = await server.measurementSubscriberUpdates()
        try await subscribeAndWait(fake: fake, server: server, stream: subscriberStream)

        sequence.release(CrankRevolution(cumulativeRevolutions: 1, lastEventTime: 1))
        try await sequence.waitUntilIteratorSuspended(index: 1)
        #expect(updateValueCalls(await fake.recordedCalls).isEmpty)
        #expect(sequence.overlapped == false)

        let expected = CSCMeasurement(cumulativeCrankRevolutions: 2, lastCrankEventTime: 2).encode()!
        sequence.release(CrankRevolution(cumulativeRevolutions: 2, lastEventTime: 2))
        try await fake.waitUntilRecordedCallsSatisfy { calls in
            hasUpdateValue(calls, value: expected)
        }
        #expect(updateValueCalls(await fake.recordedCalls).count == 1)

        await server.stop()
        _ = try await session2.value
    }

    @Test func peripheralSwapDropsStalePull() async throws {
        let fakeA = FakeBluetoothPeripheral(initialState: .poweredOn)
        let fakeB = FakeBluetoothPeripheral(initialState: .poweredOn)
        let sequence = GatedCrankSequence()
        let server = crankServer(sequence)

        let sessionA = Task { try await server.start(peripheral: fakeA) }
        try await waitForAdvertising(fakeA)
        try await sequence.waitUntilSuspended()
        await server.stop()
        _ = try await sessionA.value

        let sessionB = Task { try await server.start(peripheral: fakeB) }
        try await waitForAdvertising(fakeB)

        let subscriberStream = await server.measurementSubscriberUpdates()
        try await subscribeAndWait(fake: fakeB, server: server, stream: subscriberStream)

        sequence.release(CrankRevolution(cumulativeRevolutions: 1, lastEventTime: 1))
        try await sequence.waitUntilIteratorSuspended(index: 1)
        #expect(updateValueCalls(await fakeB.recordedCalls).isEmpty)
        #expect(updateValueCalls(await fakeA.recordedCalls).isEmpty)

        let expected = CSCMeasurement(cumulativeCrankRevolutions: 2, lastCrankEventTime: 2).encode()!
        sequence.release(CrankRevolution(cumulativeRevolutions: 2, lastEventTime: 2))
        try await fakeB.waitUntilRecordedCallsSatisfy { calls in
            hasUpdateValue(calls, value: expected)
        }
        #expect(updateValueCalls(await fakeA.recordedCalls).isEmpty)

        await server.stop()
        _ = try await sessionB.value
    }

    // MARK: - Failures

    @Test func failNextAddThenRetry() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let server = crankServer()

        await fake.failNextAdd()
        await #expect(throws: ServerError.self) {
            try await server.start(peripheral: fake)
        }
        let calls = await fake.recordedCalls
        #expect(!calls.contains { if case .startAdvertising = $0 { return true } else { return false } })

        let retry = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)
        try await emitFeatureRead(fake: fake, server: server, offset: 0, expected: Data([0x02, 0x00]))
        await server.stop()
        _ = try await retry.value
    }

    @Test func failNextAdvertise() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let server = Server.crankRevolutions(EmptyCrankSequence()).build()

        await fake.failNextAdvertise()
        await #expect(throws: ServerError.self) {
            try await server.start(peripheral: fake)
        }
        #expect(await recordedContains(fake, .removeService(uuid: CSCS.serviceUUID)))
        #expect(await fake.isAdvertising == false)

        let retryTask = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertisingCount(fake, atLeast: 2)
        await server.stop()
        _ = try await retryTask.value
    }

    @Test func failNextUpdateValuePublishFailed() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let sequence = GatedCrankSequence()
        let server = crankServer(sequence)

        let startTask = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)
        let subscriberStream = await server.measurementSubscriberUpdates()
        try await subscribeAndWait(fake: fake, server: server, stream: subscriberStream)
        await fake.failNextUpdateValue()
        sequence.release(CrankRevolution(cumulativeRevolutions: 1, lastEventTime: 1))

        await #expect(throws: ServerError.self) { try await startTask.value }
        #expect(updateValueCalls(await fake.recordedCalls).count == 1)
        #expect(await fake.isAdvertising == false)
        await server.stop()

        let retry = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertisingCount(fake, atLeast: 2)
        let stream = await server.measurementSubscriberUpdates()
        try await subscribeAndWait(fake: fake, server: server, stream: stream)
        sequence.release(CrankRevolution(cumulativeRevolutions: 3, lastEventTime: 3))
        try await fake.waitUntilRecordedCallsSatisfy { calls in updateValueCalls(calls).count >= 2 }
        await server.stop()
        _ = try await retry.value
    }

    @Test func cancelWinsOverFailNextAdd() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let server = crankServer()
        await fake.failNextAdd()

        let startTask = Task { try await server.start(peripheral: fake) }
        startTask.cancel()
        await #expect(throws: CancellationError.self) { try await startTask.value }

        let calls = await fake.recordedCalls
        #expect(!calls.contains { if case .startAdvertising = $0 { return true } else { return false } })

        let retry = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)
        await server.stop()
        _ = try await retry.value
    }

    // MARK: - Power

    @Test func initialPoweredOffThrowsBluetoothUnavailable() async throws {
        for state in [BluetoothState.poweredOff, .unauthorized, .unsupported] {
            let fake = FakeBluetoothPeripheral(initialState: state)
            let server = crankServer()
            await #expect(throws: ServerError.bluetoothUnavailable) {
                try await server.start(peripheral: fake)
            }
            #expect(!hasAdd(await fake.recordedCalls))
        }
    }

    @Test func unknownBecomesPoweredOnStaysUp() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .unknown)
        let server = crankServer()
        let flag = LockedFlag()

        let startTask = Task {
            try await server.start(peripheral: fake)
            await flag.set(true)
        }

        await fake.setState(.poweredOn)
        try await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.contains { if case .startAdvertising = $0 { return true } else { return false } }
        }
        #expect(await flag.value == false)
        #expect(await fake.isAdvertising)
        try await emitFeatureRead(fake: fake, server: server, offset: 0, expected: Data([0x02, 0x00]))
        #expect(await flag.value == false)

        await server.stop()
        _ = try await startTask.value
        #expect(await flag.value == true)
    }

    @Test func unknownTimeoutZeroBluetoothUnavailable() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .unknown)
        let server = crankServer()
        await #expect(throws: ServerError.bluetoothUnavailable) {
            try await server.start(peripheral: fake, poweredOnTimeoutNanoseconds: 0)
        }
        #expect(!hasAdd(await fake.recordedCalls))
    }

    @Test func cancelWhileUnknown() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .unknown)
        let server = crankServer()
        let startTask = Task { try await server.start(peripheral: fake) }
        try await fake.waitUntilCurrentStateReadCount(atLeast: 1)
        let start = ContinuousClock.now
        startTask.cancel()
        await #expect(throws: CancellationError.self) { try await startTask.value }
        #expect(!hasAdd(await fake.recordedCalls))
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func stopWhileUnknown() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .unknown)
        let server = crankServer()
        let startTask = Task { try await server.start(peripheral: fake) }
        try await fake.waitUntilCurrentStateReadCount(atLeast: 1)
        let start = ContinuousClock.now
        let stopTask = Task { await server.stop() }
        _ = try await startTask.value
        await stopTask.value
        #expect(!hasAdd(await fake.recordedCalls))
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    // MARK: - Subscribers

    @Test func noSubscriberDiscardsSample() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let sequence = GatedCrankSequence()
        let server = crankServer(sequence)

        let startTask = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)

        let subscriberStream = await server.measurementSubscriberUpdates()
        sequence.release(CrankRevolution(cumulativeRevolutions: 1, lastEventTime: 1))
        try await sequence.waitUntilPullCompleted(count: 1)
        #expect(updateValueCalls(await fake.recordedCalls).isEmpty)

        await fake.emitSubscription(
            .subscribed(centralID: centralID, serviceUUID: CSCS.serviceUUID, characteristicUUID: CSCS.measurementUUID),
        )
        try await waitForSubscriber(stream: subscriberStream, centralID: centralID)

        sequence.release(CrankRevolution(cumulativeRevolutions: 2, lastEventTime: 2))
        try await fake.waitUntilRecordedCallsSatisfy { calls in updateValueCalls(calls).count == 1 }

        await server.stop()
        _ = try await startTask.value
    }

    @Test func twoCentralsNotifyBothThenOne() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let sequence = GatedCrankSequence()
        let server = crankServer(sequence)
        let centralB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        let startTask = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)

        let subscriberStream = await server.measurementSubscriberUpdates()
        await fake.emitSubscription(
            .subscribed(centralID: centralID, serviceUUID: CSCS.serviceUUID, characteristicUUID: CSCS.measurementUUID),
        )
        try await waitForSubscriber(stream: subscriberStream, centralID: centralID)
        await fake.emitSubscription(
            .subscribed(centralID: centralB, serviceUUID: CSCS.serviceUUID, characteristicUUID: CSCS.measurementUUID),
        )
        try await waitForSubscribers(stream: subscriberStream, centralIDs: [centralID, centralB])

        sequence.release(CrankRevolution(cumulativeRevolutions: 1, lastEventTime: 1))
        let sorted = [centralID, centralB].sorted { $0.uuidString < $1.uuidString }
        try await fake.waitUntilRecordedCallsSatisfy { calls in
            updateValueCalls(calls).contains { call in
                if case let .updateValue(_, _, _, .only(ids)) = call {
                    return ids == sorted
                }
                return false
            }
        }

        await fake.emitSubscription(
            .unsubscribed(centralID: centralB, serviceUUID: CSCS.serviceUUID, characteristicUUID: CSCS.measurementUUID),
        )
        try await waitForSubscribers(stream: subscriberStream, centralIDs: [centralID])

        sequence.release(CrankRevolution(cumulativeRevolutions: 2, lastEventTime: 2))
        try await fake.waitUntilRecordedCallsSatisfy { calls in
            updateValueCalls(calls).filter { call in
                if case let .updateValue(_, _, _, .only(ids)) = call {
                    return ids == [centralID]
                }
                return false
            }.count == 1
        }

        await server.stop()
        _ = try await startTask.value
    }

    // MARK: - Backpressure

    @Test func backpressureRetriesAfterReady() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let sequence = GatedCrankSequence()
        let server = crankServer(sequence)

        let startTask = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)
        let subscriberStream = await server.measurementSubscriberUpdates()
        try await subscribeAndWait(fake: fake, server: server, stream: subscriberStream)

        await fake.setNextUpdateValueAccepted(false)
        sequence.release(CrankRevolution(cumulativeRevolutions: 1, lastEventTime: 1))
        try await fake.waitUntilRecordedCallsSatisfy { calls in updateValueCalls(calls).count == 1 }
        #expect(sequence.pullsCompleted == 1)

        await fake.setNextUpdateValueAccepted(true)
        await fake.emitReadyToUpdateSubscribers()
        try await fake.waitUntilRecordedCallsSatisfy { calls in updateValueCalls(calls).count == 2 }
        #expect(sequence.pullsCompleted == 1)

        await server.stop()
        _ = try await startTask.value
    }

    @Test func stopDuringBackpressure() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let sequence = GatedCrankSequence()
        let server = crankServer(sequence)

        let startTask = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)
        let subscriberStream = await server.measurementSubscriberUpdates()
        try await subscribeAndWait(fake: fake, server: server, stream: subscriberStream)

        await fake.setNextUpdateValueAccepted(false)
        sequence.release(CrankRevolution(cumulativeRevolutions: 1, lastEventTime: 1))
        try await fake.waitUntilRecordedCallsSatisfy { calls in updateValueCalls(calls).count == 1 }

        let start = ContinuousClock.now
        await server.stop()
        _ = try await startTask.value
        #expect(updateValueCalls(await fake.recordedCalls).count == 1)
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    // MARK: - Sequence behavior

    @Test func finiteSequenceCleanEOF() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let sequence = GatedCrankSequence()
        let server = crankServer(sequence)

        let startTask = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)
        let subscriberStream = await server.measurementSubscriberUpdates()
        try await subscribeAndWait(fake: fake, server: server, stream: subscriberStream)

        sequence.release(CrankRevolution(cumulativeRevolutions: 1, lastEventTime: 1))
        try await fake.waitUntilRecordedCallsSatisfy { calls in updateValueCalls(calls).count == 1 }
        sequence.releaseNil()
        try await sequence.waitUntilPullCompleted(count: 2)

        try await emitFeatureRead(fake: fake, server: server, offset: 0, expected: Data([0x02, 0x00]))
        #expect(await fake.isAdvertising)

        await server.stop()
        _ = try await startTask.value
    }

    @Test func cleanEOFRestartPullsAgain() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let sequence = GatedCrankSequence()
        let server = crankServer(sequence)

        let first = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)
        let stream = await server.measurementSubscriberUpdates()
        try await subscribeAndWait(fake: fake, server: server, stream: stream)
        sequence.release(CrankRevolution(cumulativeRevolutions: 1, lastEventTime: 1))
        try await fake.waitUntilRecordedCallsSatisfy { calls in updateValueCalls(calls).count == 1 }
        sequence.releaseNil()
        try await sequence.waitUntilPullCompleted(count: 2)
        await server.stop()
        _ = try await first.value

        let second = Task { try await server.start(peripheral: fake) }
        try await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.filter { if case .startAdvertising = $0 { return true } else { return false } }.count >= 2
        }
        let stream2 = await server.measurementSubscriberUpdates()
        try await subscribeAndWait(fake: fake, server: server, stream: stream2)
        sequence.release(CrankRevolution(cumulativeRevolutions: 5, lastEventTime: 5))
        try await fake.waitUntilRecordedCallsSatisfy { calls in updateValueCalls(calls).count == 2 }
        await server.stop()
        _ = try await second.value
    }

    @Test func throwingSequenceFails() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOn)
        let server = Server.crankRevolutions(ThrowingCrankSequence()).build()

        let startTask = Task { try await server.start(peripheral: fake) }
        try await waitForAdvertising(fake)
        await #expect(throws: ServerError.self) { try await startTask.value }
        #expect(await recordedContains(fake, .removeService(uuid: CSCS.serviceUUID)))
        #expect(await fake.isAdvertising == false)
        await server.stop()
    }

    // MARK: - Helpers

    private func waitForAdvertising(_ fake: FakeBluetoothPeripheral) async throws {
        try await waitForAdvertisingCount(fake, atLeast: 1)
    }

    private func waitForAdvertisingCount(
        _ fake: FakeBluetoothPeripheral,
        atLeast count: Int,
    ) async throws {
        try await fake.waitUntilRecordedCallsSatisfy { calls in
            advertisingCallCount(calls) >= count
                && addCallCount(calls) >= count
        }
    }

    private func advertisingCallCount(_ calls: [FakeBluetoothPeripheral.RecordedCall]) -> Int {
        calls.filter { if case .startAdvertising = $0 { return true } else { return false } }.count
    }

    private func addCallCount(_ calls: [FakeBluetoothPeripheral.RecordedCall]) -> Int {
        calls.filter { if case .add = $0 { return true } else { return false } }.count
    }

    private func subscribeAndWait(
        fake: FakeBluetoothPeripheral,
        server: Server,
        stream: AsyncStream<Set<UUID>>,
    ) async throws {
        await fake.emitSubscription(
            .subscribed(centralID: centralID, serviceUUID: CSCS.serviceUUID, characteristicUUID: CSCS.measurementUUID),
        )
        try await waitForSubscriber(stream: stream, centralID: centralID)
    }

    private func waitForSubscriber(stream: AsyncStream<Set<UUID>>, centralID: UUID) async throws {
        var iterator = stream.makeAsyncIterator()
        while let set = await iterator.next() {
            if set.contains(centralID) { return }
        }
        Issue.record("Subscriber stream ended before central appeared")
    }

    private func waitForSubscribers(stream: AsyncStream<Set<UUID>>, centralIDs: [UUID]) async throws {
        let expected = Set(centralIDs)
        var iterator = stream.makeAsyncIterator()
        while let set = await iterator.next() {
            if set == expected { return }
        }
        Issue.record("Subscriber stream ended before expected set")
    }

    private func emitFeatureRead(
        fake: FakeBluetoothPeripheral,
        server: Server,
        offset: Int,
        expected: Data,
    ) async throws {
        try await emitRead(
            fake: fake,
            server: server,
            characteristicUUID: CSCS.featureUUID,
            offset: offset,
            expectedResult: .success,
            expectedValue: expected,
        )
    }

    private func emitRead(
        fake: FakeBluetoothPeripheral,
        server: Server,
        characteristicUUID: UUID,
        offset: Int,
        expectedResult: ATTResult,
        expectedValue: Data?,
    ) async throws {
        let requestID = UUID()
        await fake.emitRead(
            PeripheralReadRequest(
                id: requestID,
                centralID: centralID,
                serviceUUID: server.service.uuid,
                characteristicUUID: characteristicUUID,
                offset: offset,
            ),
        )
        try await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.contains {
                if case let .respond(id, result, value) = $0 {
                    return id == requestID && result == expectedResult && value == expectedValue
                }
                return false
            }
        }
    }

    private func updateValueCalls(
        _ calls: [FakeBluetoothPeripheral.RecordedCall],
    ) -> [FakeBluetoothPeripheral.RecordedCall] {
        calls.filter {
            if case .updateValue = $0 { return true }
            return false
        }
    }

    private func hasUpdateValue(_ calls: [FakeBluetoothPeripheral.RecordedCall], value: Data) -> Bool {
        updateValueCalls(calls).contains { call in
            if case let .updateValue(payload, _, _, _) = call {
                return payload == value
            }
            return false
        }
    }

    private func hasAdd(_ calls: [FakeBluetoothPeripheral.RecordedCall]) -> Bool {
        calls.contains { if case .add = $0 { return true } else { return false } }
    }

    private func recordedContains(
        _ fake: FakeBluetoothPeripheral,
        _ expected: FakeBluetoothPeripheral.RecordedCall,
    ) async -> Bool {
        await fake.recordedCalls.contains(expected)
    }
}

// MARK: - Gated crank sequence

private final class GatedCrankSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var iterators: [GatedIterator] = []
    private var pendingByIterator: [UUID: ReleaseValue] = [:]
    private var pendingBeforeIterator: ReleaseValue?
    private var pullWaiters: [(count: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var suspendWaiters: [(index: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var iteratorExistenceWaiters: [CheckedContinuation<Void, Error>] = []
    private(set) var pullsCompleted = 0
    private(set) var makeAsyncIteratorCallCount = 0
    private(set) var overlapped = false

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    enum ReleaseValue {
        case revolution(CrankRevolution)
        case nilValue
    }

    func release(_ revolution: CrankRevolution) {
        release(.revolution(revolution))
    }

    func releaseNil() {
        release(.nilValue)
    }

    private func release(_ value: ReleaseValue) {
        let suspended: GatedIterator? = withLock {
            if let suspended = iterators.first(where: { $0.isSuspended && $0.pendingRelease == nil }) {
                return suspended
            }
            if let target = iterators.last {
                if pendingByIterator[target.id] != nil {
                    Issue.record("Second resume while one is already pending")
                    return nil
                }
                pendingByIterator[target.id] = value
                return nil
            }
            pendingBeforeIterator = value
            return nil
        }
        suspended?.resume(value)
    }

    func makeIterator() -> GatedIterator {
        withLock {
            if iterators.contains(where: { $0.isSuspended }) {
                overlapped = true
            }
            makeAsyncIteratorCallCount += 1
            let iterator = GatedIterator(sequence: self)
            if let pending = pendingBeforeIterator {
                pendingBeforeIterator = nil
                pendingByIterator[iterator.id] = pending
            }
            iterators.append(iterator)
            let ready = iteratorExistenceWaiters
            iteratorExistenceWaiters = []
            for waiter in ready {
                waiter.resume()
            }
            return iterator
        }
    }

    fileprivate func completePull(iterator: GatedIterator) {
        withLock {
            pullsCompleted += 1
            pendingByIterator.removeValue(forKey: iterator.id)
            let ready = pullWaiters.filter { pullsCompleted >= $0.count }
            pullWaiters.removeAll { pullsCompleted >= $0.count }
            for waiter in ready {
                waiter.continuation.resume()
            }
        }
    }

    fileprivate func pendingRelease(for iterator: GatedIterator) -> ReleaseValue? {
        withLock { pendingByIterator[iterator.id] }
    }

    fileprivate func clearPending(for iterator: GatedIterator) {
        withLock { pendingByIterator.removeValue(forKey: iterator.id) }
    }

    fileprivate func markSuspended(_ iterator: GatedIterator) {
        withLock {
            guard let index = iterators.firstIndex(where: { $0.id == iterator.id }) else { return }
            let ready = suspendWaiters.filter { $0.index == index }
            suspendWaiters.removeAll { $0.index == index }
            for waiter in ready {
                waiter.continuation.resume()
            }
        }
    }

    func waitUntilIteratorExists() async throws {
        if withLock({ !iterators.isEmpty }) {
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            withLock {
                if !iterators.isEmpty {
                    continuation.resume()
                } else {
                    iteratorExistenceWaiters.append(continuation)
                }
            }
        }
    }

    func waitUntilPullCompleted(count: Int) async throws {
        if withLock({ pullsCompleted >= count }) {
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            withLock {
                if pullsCompleted >= count {
                    continuation.resume()
                } else {
                    pullWaiters.append((count, continuation))
                }
            }
        }
    }

    func waitUntilSuspended() async throws {
        try await waitUntilIteratorSuspended(index: 0)
    }

    func waitUntilIteratorSuspended(index: Int) async throws {
        if withLock({ iterators.indices.contains(index) && iterators[index].isSuspended }) {
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            withLock {
                if iterators.indices.contains(index), iterators[index].isSuspended {
                    continuation.resume()
                } else {
                    suspendWaiters.append((index, continuation))
                }
            }
        }
    }
}

private struct GatedAsyncSequence: AsyncSequence, Sendable {
    typealias Element = CrankRevolution
    let sequence: GatedCrankSequence

    struct Iterator: AsyncIteratorProtocol, Sendable {
        private let gated: GatedIterator

        init(gated: GatedIterator) {
            self.gated = gated
        }

        func next() async throws -> CrankRevolution? {
            try await gated.next()
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(gated: sequence.makeIterator())
    }
}

private final class GatedIterator: @unchecked Sendable {
    let id = UUID()
    private weak var sequence: GatedCrankSequence?
    private var continuation: CheckedContinuation<CrankRevolution?, Error>?
    private(set) var isSuspended = false
    private(set) var pendingRelease: GatedCrankSequence.ReleaseValue?

    init(sequence: GatedCrankSequence) {
        self.sequence = sequence
    }

    func next() async throws -> CrankRevolution? {
        if let pendingRelease {
            let pending = pendingRelease
            self.pendingRelease = nil
            return resolve(pending)
        }
        if let pending = sequence?.pendingRelease(for: self) {
            sequence?.clearPending(for: self)
            return resolve(pending)
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.isSuspended = true
            self.sequence?.markSuspended(self)
        }
    }

    func resume(_ value: GatedCrankSequence.ReleaseValue) {
        if let continuation {
            self.continuation = nil
            self.isSuspended = false
            continuation.resume(returning: resolve(value))
        } else {
            pendingRelease = value
        }
    }

    private func resolve(_ value: GatedCrankSequence.ReleaseValue) -> CrankRevolution? {
        switch value {
        case let .revolution(revolution):
            sequence?.completePull(iterator: self)
            return revolution
        case .nilValue:
            sequence?.completePull(iterator: self)
            return nil
        }
    }
}

private struct ThrowingCrankSequence: AsyncSequence, Sendable {
    struct Iterator: AsyncIteratorProtocol, Sendable {
        func next() async throws -> CrankRevolution? {
            throw TestSequenceError.boom
        }
    }

    func makeAsyncIterator() -> Iterator { Iterator() }
}

private enum TestSequenceError: Error {
    case boom
}

private struct EmptyCrankSequence: AsyncSequence, Sendable {
    typealias Element = CrankRevolution

    struct Iterator: AsyncIteratorProtocol, Sendable {
        func next() async throws -> CrankRevolution? { nil }
    }

    func makeAsyncIterator() -> Iterator { Iterator() }
}

private struct SingleCrankSequence: AsyncSequence, Sendable {
    let element: CrankRevolution

    struct Iterator: AsyncIteratorProtocol, Sendable {
        var yielded = false
        let element: CrankRevolution

        mutating func next() async throws -> CrankRevolution? {
            guard !yielded else { return nil }
            yielded = true
            return element
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(element: element)
    }
}

private struct EmptyWheelSequence: AsyncSequence, Sendable {
    typealias Element = WheelRevolution

    struct Iterator: AsyncIteratorProtocol, Sendable {
        func next() async throws -> WheelRevolution? { nil }
    }

    func makeAsyncIterator() -> Iterator { Iterator() }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set(_ value: Bool) {
        lock.lock()
        flag = value
        lock.unlock()
    }
}

private final class CumulativeSpy: SetCumulativeWheelRevolutions, @unchecked Sendable {
    private(set) var setCount = 0
    func setCumulativeWheelRevolutions(_ cumulativeRevolutions: UInt32) async throws {
        setCount += 1
    }
}

private final class LocationsSpy: MultipleSensorLocationsDelegate, @unchecked Sendable {
    var supported: [SensorLocationKind]
    var current: SensorLocationKind
    private(set) var updateCount = 0

    init(supported: [SensorLocationKind], current: SensorLocationKind) {
        self.supported = supported
        self.current = current
    }

    func update(_ location: SensorLocationKind) async throws {
        updateCount += 1
        current = location
    }
}

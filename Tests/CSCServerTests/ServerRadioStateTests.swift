import CSCServer
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ServerRadioStateTests {
    @Test(arguments: [BluetoothState.unauthorized, .unsupported])
    func startupFailsFastForUnavailableStates(state: BluetoothState) async throws {
        let fake = FakeBluetoothPeripheral(initialState: state)
        let server = Server.crankRevolutions(NeverYieldingCrankSequence()).build()

        await #expect(throws: ServerError.notPoweredOn) {
            try await server.start(peripheral: fake)
        }
        #expect(await fake.recordedCalls.isEmpty)
    }

    @Test func startupWaitEndsWhenUnknownBecomesUnauthorized() async throws {
        let fake = FakeBluetoothPeripheral(initialState: .unknown)
        let server = Server.crankRevolutions(NeverYieldingCrankSequence()).build()

        let startTask = Task {
            try await server.start(peripheral: fake)
        }
        await fake.waitForStateUpdatesSubscriber()
        await fake.setState(.unauthorized)

        await #expect(throws: ServerError.notPoweredOn) {
            try await startTask.value
        }
        #expect(await fake.recordedCalls.isEmpty)
    }

    @Test func powerLossDuringAdvertiseThrowsNotPoweredOn() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(NeverYieldingCrankSequence()).build()
        await fake.holdNextAdvertise()

        let startTask = Task {
            try await server.start(peripheral: fake)
        }
        await fake.waitUntilAdvertiseHeld()
        await fake.setState(.poweredOff)
        await fake.releaseAdvertise()

        await #expect(throws: ServerError.notPoweredOn) {
            try await startTask.value
        }
        #expect(await fake.recordedCalls == [
            .add(server.configuration.service),
            .removeService(uuid: CSCS.serviceUUID),
        ])
        #expect(await fake.isAdvertising == false)
    }

    @Test func powerLossDuringAddThrowsNotPoweredOn() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(NeverYieldingCrankSequence()).build()
        await fake.holdNextAdd()

        let startTask = Task {
            try await server.start(peripheral: fake)
        }
        await fake.waitUntilAddHeld()
        await fake.setState(.poweredOff)
        await fake.releaseAdd()

        await #expect(throws: ServerError.notPoweredOn) {
            try await startTask.value
        }
        #expect(await fake.recordedCalls.isEmpty)
        #expect(await fake.isAdvertising == false)
    }

    @Test func lossClearsSubscribersAndDropsSamples() async throws {
        let wheel = YieldingWheelSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(wheel, setCumulativeWheelRevolutions: ScriptedCumulativeDelegate())
            .build()
        try await server.start(peripheral: fake)
        let central = UUID()
        await fake.subscribeMeasurement(server: server, centralID: central)

        let sample1 = WheelRevolution(cumulativeRevolutions: 1, lastEventTime: 10)
        let sample2 = WheelRevolution(cumulativeRevolutions: 2, lastEventTime: 20)
        let sample3 = WheelRevolution(cumulativeRevolutions: 3, lastEventTime: 30)
        await wheel.yield(sample1)
        await server.waitUntilAcceptedMeasurementCount(1)

        await fake.setState(.poweredOff)
        await server.waitForMeasurementSubscribers([])

        await wheel.yield(sample2)
        await wheel.waitUntilNextEntered(count: 3)

        await fake.setState(.poweredOn)
        await fake.waitUntilCallCount(2, matching: isStartAdvertising)
        await fake.subscribeMeasurement(server: server, centralID: central)

        let payload3 = Self.wheelPayload(sample3)
        await wheel.yield(sample3)
        await fake.waitUntilUpdateValueCount(1, characteristic: CSCS.measurementUUID, matching: { $0 == payload3 })

        let payload2 = Self.wheelPayload(sample2)
        #expect(await fake.countUpdateValues(characteristic: CSCS.measurementUUID, matching: { $0 == payload2 }) == 0)
    }

    @Test func inFlightMeasurementDuringLossIsNotCached() async throws {
        let wheel = YieldingWheelSequence()
        let crank = YieldingCrankSequence()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(wheel, setCumulativeWheelRevolutions: ScriptedCumulativeDelegate())
            .crankRevolutions(crank)
            .build()
        try await server.start(peripheral: fake)
        let central = UUID()
        await fake.subscribeMeasurement(server: server, centralID: central)

        await fake.holdNextUpdateValue()
        await wheel.yield(WheelRevolution(cumulativeRevolutions: 100, lastEventTime: 1))
        await fake.waitUntilUpdateValueHeld()

        await fake.setState(.poweredOff)
        await server.waitForMeasurementSubscribers([])
        await fake.releaseUpdateValue()
        await wheel.waitUntilNextEntered(count: 2)

        await fake.setState(.poweredOn)
        await fake.waitUntilCallCount(2, matching: isStartAdvertising)
        await fake.subscribeMeasurement(server: server, centralID: central)

        let crankPayload = CSCMeasurement(cumulativeCrankRevolutions: 5, lastCrankEventTime: 6).encode()!
        await crank.yield(CrankRevolution(cumulativeRevolutions: 5, lastEventTime: 6))
        await fake.waitUntilUpdateValueCount(
            1,
            characteristic: CSCS.measurementUUID,
            matching: { CSCMeasurement.decode($0)?.cumulativeCrankRevolutions == 5 },
        )

        let sent = await fake.recordedCalls.compactMap { call -> Data? in
            if case let .updateValue(value, _, CSCS.measurementUUID, _) = call,
               CSCMeasurement.decode(value)?.cumulativeCrankRevolutions == 5
            {
                return value
            }
            return nil
        }
        #expect(sent == [crankPayload])
        #expect(CSCMeasurement.decode(sent[0])?.cumulativeWheelRevolutions == nil)
    }

    @Test(arguments: [
        BluetoothState.poweredOff,
        .resetting,
        .unauthorized,
        .unsupported,
        .unknown,
    ])
    func lossRepublishesSameServiceWhenPoweredOnReturns(state: BluetoothState) async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(NeverYieldingCrankSequence())
            .staticSensorLocation(.leftCrank)
            .build()
        try await server.start(peripheral: fake)
        let central = UUID()
        await fake.subscribeMeasurement(server: server, centralID: central)

        await fake.setState(state)
        await server.waitForMeasurementSubscribers([])
        #expect(await fake.isAdvertising == false)

        await fake.setState(.poweredOn)
        await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.filter(isAdd).count == 2 && calls.filter(isStartAdvertising).count == 2
        }
        #expect(Array(await fake.recordedCalls.dropFirst(2)) == [
            .stopAdvertising,
            .removeService(uuid: CSCS.serviceUUID),
            .add(server.configuration.service),
            .startAdvertising(cscAdvertisement),
        ])

        #expect(await fake.read(characteristicUUID: CSCS.featureUUID) == Data([0x02, 0x00]))
        #expect(await fake.read(characteristicUUID: CSCS.sensorLocationUUID) == Data([0x05]))
    }

    @Test func lossEndsBackpressuredIndicationProcedure() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(NeverYieldingWheelSequence(), setCumulativeWheelRevolutions: delegate)
            .build()
        try await server.start(peripheral: fake)
        let writer = UUID()
        await fake.subscribeControlPoint(server: server, centralID: writer)
        let success = controlPointResponse(opcode: 0x01, value: 0x01)

        await fake.setNextUpdateValueAccepted(false)
        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: setCumulativeValue(1))) == .success)
        await fake.waitUntilUpdateValueCount(1, characteristic: CSCS.controlPointUUID, matching: { $0 == success })

        await fake.setState(.poweredOff)
        await server.waitUntilControlPointProcedureIdle()

        await fake.setState(.poweredOn)
        await fake.waitUntilCallCount(2, matching: isStartAdvertising)
        await fake.setNextUpdateValueAccepted(true)
        await fake.subscribeControlPoint(server: server, centralID: writer)

        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: setCumulativeValue(2))) == .success)
        await fake.waitUntilUpdateValueCount(2, characteristic: CSCS.controlPointUUID, matching: { $0 == success })
        await server.waitUntilControlPointProcedureIdle()
        #expect(await fake.countUpdateValues(characteristic: CSCS.controlPointUUID, matching: { $0 == success }) == 2)
    }

    @Test func lossDuringParkedDelegateSuppressesIndication() async throws {
        let delegate = ScriptedCumulativeDelegate()
        await delegate.armParkForNextCall()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(NeverYieldingWheelSequence(), setCumulativeWheelRevolutions: delegate)
            .build()
        try await server.start(peripheral: fake)
        let writer = UUID()
        await fake.subscribeControlPoint(server: server, centralID: writer)

        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: setCumulativeValue(1))) == .success)
        await delegate.waitUntilRecordedCount(1)

        await fake.setState(.poweredOff)
        await server.waitForControlPointSubscribers([])
        await delegate.release()
        await server.waitUntilControlPointProcedureIdle()

        #expect(await fake.countUpdateValues(characteristic: CSCS.controlPointUUID) == 0)
    }

    @Test func recoveryFailureStaysSuspendedUntilNextPowerCycle() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(NeverYieldingCrankSequence()).build()
        try await server.start(peripheral: fake)
        let central = UUID()
        await fake.subscribeMeasurement(server: server, centralID: central)
        await fake.failNextAdd()

        await fake.setState(.poweredOff)
        await server.waitForMeasurementSubscribers([])
        await fake.setState(.poweredOn)
        await fake.waitUntilCallCount(2, matching: isAdd)

        #expect(await server.isRadioSuspended)
        #expect(await fake.recordedCalls.filter(isStartAdvertising).count == 1)
        #expect(await fake.isAdvertising == false)
        await server.waitForMeasurementSubscribers([])

        await fake.setState(.poweredOff)
        await fake.setState(.poweredOn)
        await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.filter(isAdd).count == 3 && calls.filter(isStartAdvertising).count == 2
        }

        #expect(await server.isRadioSuspended == false)
        #expect(await fake.isAdvertising)
        #expect(Array(await fake.recordedCalls.dropFirst(2)) == [
            .stopAdvertising,
            .removeService(uuid: CSCS.serviceUUID),
            .add(server.configuration.service),
            .stopAdvertising,
            .add(server.configuration.service),
            .startAdvertising(cscAdvertisement),
        ])
    }

    @Test func stopWhileSuspendedReturnsAndDoesNotRepublish() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(NeverYieldingCrankSequence()).build()
        try await server.start(peripheral: fake)
        let central = UUID()
        await fake.subscribeMeasurement(server: server, centralID: central)

        await fake.setState(.poweredOff)
        await server.waitForMeasurementSubscribers([])
        await server.stop()

        await fake.setState(.poweredOn)
        try await server.start(peripheral: fake)

        #expect(await fake.recordedCalls.filter(isAdd).count == 2)
        await server.stop()
    }

    @Test func stopDuringRecoveryLeavesNothingAdvertising() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(NeverYieldingCrankSequence()).build()
        try await server.start(peripheral: fake)
        await fake.holdNextAdvertise()

        await fake.setState(.poweredOff)
        await fake.setState(.poweredOn)
        await fake.waitUntilAdvertiseHeld()

        let stopTask = Task {
            await server.stop()
        }
        await fake.waitUntilCallCount(2, matching: isRemoveService)
        await fake.releaseAdvertise()
        await stopTask.value

        #expect(await fake.isAdvertising == false)
        #expect(Array(await fake.recordedCalls.dropFirst(2)) == [
            .stopAdvertising,
            .removeService(uuid: CSCS.serviceUUID),
            .add(server.configuration.service),
            .stopAdvertising,
            .removeService(uuid: CSCS.serviceUUID),
            .startAdvertising(cscAdvertisement),
            .stopAdvertising,
        ])
    }

    @Test func servedLocationSurvivesToggle() async throws {
        let locations = ScriptedLocationDelegate(supported: [.leftCrank, .rightCrank], current: .leftCrank)
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(NeverYieldingCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        try await server.start(peripheral: fake)
        let writer = UUID()
        await fake.subscribeControlPoint(server: server, centralID: writer)

        #expect(await fake.writeControlPoint(
            controlPointWrite(centralID: writer, value: updateSensorLocationValue(.rightCrank)),
        ) == .success)
        await fake.waitUntilUpdateValueCount(
            1,
            characteristic: CSCS.controlPointUUID,
            matching: { $0 == controlPointResponse(opcode: 0x03, value: 0x01) },
        )

        await fake.setState(.poweredOff)
        await fake.setState(.poweredOn)
        await fake.waitUntilCallCount(2, matching: isStartAdvertising)

        #expect(await fake.read(characteristicUUID: CSCS.sensorLocationUUID) == Data([0x06]))
    }

    @Test func lossAndReturnDuringStartupFailsStart() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(NeverYieldingCrankSequence()).build()
        await fake.holdNextAdvertise()

        let startTask = Task {
            try await server.start(peripheral: fake)
        }
        await fake.waitUntilAdvertiseHeld()
        await fake.setState(.poweredOff)
        await fake.setState(.poweredOn)
        await fake.releaseAdvertise()

        await #expect(throws: ServerError.notPoweredOn) {
            try await startTask.value
        }
        #expect(await fake.recordedCalls == [
            .add(server.configuration.service),
            .startAdvertising(cscAdvertisement),
            .stopAdvertising,
            .removeService(uuid: CSCS.serviceUUID),
        ])
        #expect(await fake.isAdvertising == false)

        try await server.start(peripheral: fake)
        #expect(await fake.recordedCalls.filter(isAdd).count == 2)
        await server.stop()
    }

    private static func wheelPayload(_ sample: WheelRevolution) -> Data {
        CSCMeasurement(
            cumulativeWheelRevolutions: sample.cumulativeRevolutions,
            lastWheelEventTime: sample.lastEventTime,
        ).encode()!
    }
}

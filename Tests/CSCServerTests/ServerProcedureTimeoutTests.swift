import CSCServer
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ServerProcedureTimeoutTests {
    private static let setCumulativeSuccess = controlPointResponse(opcode: 0x01, value: 0x01)

    @Test func timerArmsOnlyForAcceptedWritesWithThirtySeconds() async throws {
        let (server, fake, delegate, clock) = try await Self.startWheelServer()
        let writer = UUID()

        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: setCumulativeValue(1))) == .error(code: 0x81))
        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: Data())) == .error(code: 0x0D))
        let offsetWrite = PeripheralWriteTransaction(
            id: UUID(),
            requests: [
                PeripheralWriteRequest(
                    centralID: writer,
                    serviceUUID: CSCS.serviceUUID,
                    characteristicUUID: CSCS.controlPointUUID,
                    offset: 1,
                    value: setCumulativeValue(1),
                ),
            ],
        )
        #expect(await fake.writeControlPoint(offsetWrite) == .error(code: 0x07))
        #expect(await clock.requestedDurations.isEmpty)

        await fake.subscribeControlPoint(server: server, centralID: writer)
        await delegate.armParkForNextCall()
        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: setCumulativeValue(2))) == .success)
        await delegate.waitUntilRecordedCount(1)
        await clock.waitUntilSleeperCount(1)

        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: setCumulativeValue(3))) == .error(code: 0x80))

        await delegate.release()
        await server.waitUntil(.controlPointProcedureIdle)
        await clock.waitUntilSleeperCount(0)

        #expect(await clock.requestedDurations == [.seconds(30)])
        #expect(await delegate.recordedValues == [2])
    }

    @Test func backpressuredIndicationTimesOutAndIsNeverRetried() async throws {
        let (server, fake, delegate, clock) = try await Self.startWheelServer()
        let writer = UUID()
        await fake.subscribeControlPoint(server: server, centralID: writer)

        await fake.setNextUpdateValueAccepted(false)
        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: setCumulativeValue(1))) == .success)
        await fake.waitUntilUpdateValueCount(1, characteristic: CSCS.controlPointUUID, matching: { $0 == Self.setCumulativeSuccess })
        await clock.waitUntilSleeperCount(1)

        await clock.advance(by: .seconds(29))
        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: setCumulativeValue(2))) == .error(code: 0x80))

        await clock.advance(by: .seconds(1))
        await server.waitUntil(.controlPointProcedureIdle)

        await fake.setNextUpdateValueAccepted(true)
        await fake.emitReadyToUpdateSubscribers()
        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: setCumulativeValue(3))) == .success)
        await fake.waitUntilUpdateValueCount(2, characteristic: CSCS.controlPointUUID, matching: { $0 == Self.setCumulativeSuccess })
        await server.waitUntil(.controlPointProcedureIdle)

        #expect(await fake.countUpdateValues(characteristic: CSCS.controlPointUUID, matching: { $0 == Self.setCumulativeSuccess }) == 2)
        #expect(await delegate.recordedValues == [1, 3])
    }

    @Test func inFlightIndicationAtDeadlineIsNotRetriedOrReEnded() async throws {
        let (server, fake, delegate, clock) = try await Self.startWheelServer()
        let writer = UUID()
        await fake.subscribeControlPoint(server: server, centralID: writer)

        await fake.holdNextUpdateValue()
        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: setCumulativeValue(1))) == .success)
        await fake.waitUntilUpdateValueHeld()
        await clock.waitUntilSleeperCount(1)

        await clock.advance(by: .seconds(30))
        await server.waitUntil(.controlPointProcedureIdle)
        await fake.releaseUpdateValue()
        await fake.emitReadyToUpdateSubscribers()

        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: setCumulativeValue(2))) == .success)
        await fake.waitUntilUpdateValueCount(2, characteristic: CSCS.controlPointUUID, matching: { $0 == Self.setCumulativeSuccess })
        await server.waitUntil(.controlPointProcedureIdle)

        #expect(await fake.countUpdateValues(characteristic: CSCS.controlPointUUID, matching: { $0 == Self.setCumulativeSuccess }) == 2)
        #expect(await delegate.recordedValues == [1, 2])
    }

    @Test func cooperativeDelegateIsCancelledAtTimeoutWithoutIndication() async throws {
        let (server, fake, delegate, clock) = try await Self.startWheelServer()
        let writer = UUID()
        await fake.subscribeControlPoint(server: server, centralID: writer)

        await delegate.armParkForNextCall()
        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: setCumulativeValue(1))) == .success)
        await delegate.waitUntilRecordedCount(1)
        await clock.waitUntilSleeperCount(1)

        await clock.advance(by: .seconds(30))
        await server.waitUntil(.controlPointProcedureIdle)
        #expect(await fake.countUpdateValues(characteristic: CSCS.controlPointUUID) == 0)

        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: setCumulativeValue(2))) == .success)
        await fake.waitUntilUpdateValueCount(1, characteristic: CSCS.controlPointUUID, matching: { $0 == Self.setCumulativeSuccess })
        await server.waitUntil(.controlPointProcedureIdle)

        #expect(await fake.countUpdateValues(characteristic: CSCS.controlPointUUID) == 1)
        #expect(await delegate.recordedValues == [1, 2])
    }

    @Test func nonCooperativeUpdateHoldsProcedureUntilReturnAndIsNotIndicated() async throws {
        let locations = ScriptedLocationDelegate(supported: [.leftCrank, .rightCrank], current: .leftCrank)
        let server = Server.crankRevolutions(NeverYieldingCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        let clock = ManualServerClock()
        try await server.start(peripheral: fake, clock: clock)
        let writer = UUID()
        await fake.subscribeControlPoint(server: server, centralID: writer)

        locations.armParkIgnoringCancellationForNextCall()
        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: updateSensorLocationValue(.rightCrank))) == .success)
        await locations.waitUntilUpdateCount(1)
        await clock.waitUntilSleeperCount(1)

        await clock.advance(by: .seconds(30))
        await locations.waitUntilCancellationRequested()
        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: updateSensorLocationValue(.leftCrank))) == .error(code: 0x80))

        locations.release()
        await server.waitUntil(.controlPointProcedureIdle)

        #expect(await fake.countUpdateValues(characteristic: CSCS.controlPointUUID, matching: { $0.starts(with: [0x10, 0x03]) }) == 0)
        #expect(await fake.read(characteristicUUID: CSCS.sensorLocationUUID) == Data([0x06]))

        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: updateSensorLocationValue(.leftCrank))) == .success)
        let updateSuccess = controlPointResponse(opcode: 0x03, value: 0x01)
        await fake.waitUntilUpdateValueCount(1, characteristic: CSCS.controlPointUUID, matching: { $0 == updateSuccess })
        await server.waitUntil(.controlPointProcedureIdle)
        #expect(locations.recordedUpdateKinds == [.rightCrank, .leftCrank])
    }

    @Test func completedProcedureCancelsTimer() async throws {
        let (server, fake, delegate, clock) = try await Self.startWheelServer()
        let writer = UUID()
        await fake.subscribeControlPoint(server: server, centralID: writer)

        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: setCumulativeValue(1))) == .success)
        await fake.waitUntilUpdateValueCount(1, characteristic: CSCS.controlPointUUID, matching: { $0 == Self.setCumulativeSuccess })
        await server.waitUntil(.controlPointProcedureIdle)
        await clock.waitUntilSleeperCount(0)

        await clock.advance(by: .seconds(60))

        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: setCumulativeValue(2))) == .success)
        await fake.waitUntilUpdateValueCount(2, characteristic: CSCS.controlPointUUID, matching: { $0 == Self.setCumulativeSuccess })
        await server.waitUntil(.controlPointProcedureIdle)

        #expect(await fake.countUpdateValues(characteristic: CSCS.controlPointUUID) == 2)
        #expect(await delegate.recordedValues == [1, 2])
        #expect(await clock.requestedDurations == [.seconds(30), .seconds(30)])
    }

    @Test func timeoutRemovesQueuedIndicationBehindMeasurement() async throws {
        let wheel = YieldingWheelSequence()
        let locations = ScriptedLocationDelegate(supported: [.leftCrank, .rightCrank], current: .leftCrank)
        let server = Server.wheelRevolutions(wheel, setCumulativeWheelRevolutions: ScriptedCumulativeDelegate())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        let clock = ManualServerClock()
        try await server.start(peripheral: fake, clock: clock)
        let central = UUID()
        await fake.subscribeMeasurement(server: server, centralID: central)
        await fake.subscribeControlPoint(server: server, centralID: central)

        await fake.setNextUpdateValueAccepted(false)
        let sample = WheelRevolution(cumulativeRevolutions: 42, lastEventTime: 7)
        let wheelPayload = CSCMeasurement(
            cumulativeWheelRevolutions: sample.cumulativeRevolutions,
            lastWheelEventTime: sample.lastEventTime,
        ).encode()!
        await wheel.yield(sample)
        await fake.waitUntilUpdateValueCount(1, characteristic: CSCS.measurementUUID)

        await fake.emitWriteTransaction(
            controlPointWrite(centralID: central, value: requestSupportedSensorLocationsValue),
        )
        await server.waitUntil(.outboundCount(atLeast: 2))
        await clock.waitUntilSleeperCount(1)

        await clock.advance(by: .seconds(30))
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

    @Test func stopCancelsArmedTimer() async throws {
        let (server, fake, delegate, clock) = try await Self.startWheelServer()
        let writer = UUID()
        await fake.subscribeControlPoint(server: server, centralID: writer)

        await delegate.armParkForNextCall()
        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: setCumulativeValue(1))) == .success)
        await delegate.waitUntilRecordedCount(1)
        await clock.waitUntilSleeperCount(1)

        await server.stop()

        #expect(await clock.sleeperCount == 0)
        #expect(await fake.countUpdateValues(characteristic: CSCS.controlPointUUID) == 0)
    }

    private static func startWheelServer() async throws -> (Server, FakeBluetoothPeripheral, ScriptedCumulativeDelegate, ManualServerClock) {
        let delegate = ScriptedCumulativeDelegate()
        let server = Server.wheelRevolutions(NeverYieldingWheelSequence(), setCumulativeWheelRevolutions: delegate)
            .build()
        let fake = FakeBluetoothPeripheral()
        let clock = ManualServerClock()
        try await server.start(peripheral: fake, clock: clock)
        return (server, fake, delegate, clock)
    }
}

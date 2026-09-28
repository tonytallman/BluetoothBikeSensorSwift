import CSCClient
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct ControlPointTests {
    private func multipleLocationFake() -> FakeBluetoothCentral {
        FakeBluetoothCentral(
            featureData: CSCFeature([
                .wheelRevolutionData,
                .crankRevolutionData,
                .multipleSensorLocations,
            ]).encode(),
            discoveredCharacteristicUUIDs: FakeCharacteristicSets.allCSCCharacteristicUUIDs,
            sensorLocationData: CSCSensorLocation(assignedNumber: 0x05).encode(),
        )
    }

    @Test func controlPointProcedureInProgressGate() async throws {
        let fake = multipleLocationFake()
        let connected = try await CSCClientTestSupport.sensor(central: fake).connect()
        guard case let .multiple(locations) = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }

        await fake.holdNextControlPointIndication()

        let baseline = await CSCClientTestSupport.controlPointWrites(on: fake)
        async let writeRecorded: Void = CSCClientTestSupport.waitForControlPointWrite(
            on: fake,
            after: baseline,
        )
        let firstUpdate = Task {
            try await locations.update(locations.supported[1])
        }

        try await writeRecorded

        do {
            try await locations.update(locations.supported[2])
            Issue.record("Expected procedureInProgress")
        } catch let error as ControlPointError {
            #expect(error == .procedureInProgress)
        }

        await fake.releaseHeldControlPointIndication()
        _ = try await firstUpdate.value
        _ = try await connected.disconnect()
    }

    @Test func heldControlPointIndicationTimesOutOnUpdate() async throws {
        let fake = multipleLocationFake()
        let connected = try await CSCClientTestSupport.sensor(
            central: fake,
            timeouts: Timeouts(controlPointProcedure: .milliseconds(100)),
        ).connect()
        guard case let .multiple(locations) = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }

        await fake.holdNextControlPointIndication()

        let start = ContinuousClock.now
        do {
            try await locations.update(locations.supported[1])
            Issue.record("Expected timedOut")
        } catch let error as ControlPointError {
            #expect(error == .timedOut)
        }
        let elapsed = start.duration(to: .now)
        #expect(elapsed < .seconds(1))

        await fake.releaseHeldControlPointIndication()
        _ = try await connected.disconnect()
    }

    @Test func timedOutIndicationIsIgnoredByNextProcedure() async throws {
        let fake = multipleLocationFake()
        let connected = try await CSCClientTestSupport.sensor(
            central: fake,
            timeouts: Timeouts(controlPointProcedure: .milliseconds(100)),
        ).connect()
        guard case let .multiple(locations) = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }

        let rightCrank = locations.supported.first { $0.kind == .rightCrank }!
        let rearDropout = locations.supported.first { $0.kind == .rearDropout }!

        await fake.holdNextControlPointIndication()
        do {
            try await locations.update(rightCrank)
            Issue.record("Expected timedOut")
        } catch let error as ControlPointError {
            #expect(error == .timedOut)
        }
        #expect(locations.current.kind == .leftCrank)

        await fake.releaseHeldControlPointIndication()
        #expect(locations.current.kind == .leftCrank)

        try await locations.update(rearDropout)
        #expect(locations.current.kind == .rearDropout)

        _ = try await connected.disconnect()
    }

    @Test(arguments: [
        "controlPointWriteFailureDoesNotHangUpdate",
        "attProcedureAlreadyInProgressMapsToControlPointError",
    ])
    func controlPointWriteErrorMapsToControlPointError(caseName: String) async throws {
        let fake = multipleLocationFake()
        let connected = try await CSCClientTestSupport.sensor(central: fake).connect()
        guard case let .multiple(locations) = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }

        switch caseName {
        case "controlPointWriteFailureDoesNotHangUpdate":
            await fake.failNext(
                .writeValue,
                with: .attApplicationError(code: CSCATTApplicationError.cccdImproperlyConfigured.rawValue),
            )
            let start = ContinuousClock.now
            do {
                try await locations.update(locations.supported[1])
                Issue.record("Expected cccdImproperlyConfigured")
            } catch let error as ControlPointError {
                #expect(error == .cccdImproperlyConfigured)
            }
            #expect(start.duration(to: .now) < .seconds(1))
        case "attProcedureAlreadyInProgressMapsToControlPointError":
            await fake.failNext(
                .writeValue,
                with: .attApplicationError(code: CSCATTApplicationError.procedureAlreadyInProgress.rawValue),
            )
            do {
                try await locations.update(locations.supported[1])
                Issue.record("Expected procedureInProgress")
            } catch let error as ControlPointError {
                #expect(error == .procedureInProgress)
            }
        default:
            Issue.record("Unknown case")
        }

        _ = try await connected.disconnect()
    }

    @Test func priorProcedureWriteFinishIgnoresStaleGeneration() async throws {
        let fake = multipleLocationFake()
        let connected = try await CSCClientTestSupport.sensor(
            central: fake,
            timeouts: Timeouts(controlPointProcedure: .milliseconds(100)),
        ).connect()
        guard case let .multiple(locations) = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }

        await fake.hangNextWrite()
        do {
            try await locations.update(locations.supported[1])
            Issue.record("Expected timedOut")
        } catch let error as ControlPointError {
            #expect(error == .timedOut)
        }

        do {
            try await locations.update(locations.supported[2])
            Issue.record("Expected procedureInProgress while first write is hung")
        } catch let error as ControlPointError {
            #expect(error == .procedureInProgress)
        }

        await fake.releaseHungWrite()
        await locations.controlPoint.waitUntilIdle()
        _ = try await connected.disconnect()
    }

    @Test func timeoutReturnsWhileWriteIsStuck() async throws {
        let fake = multipleLocationFake()
        let connected = try await CSCClientTestSupport.sensor(
            central: fake,
            timeouts: Timeouts(controlPointProcedure: .milliseconds(100)),
        ).connect()
        guard case let .multiple(locations) = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }

        await fake.hangNextWrite()

        let start = ContinuousClock.now
        do {
            try await locations.update(locations.supported[1])
            Issue.record("Expected timedOut")
        } catch let error as ControlPointError {
            #expect(error == .timedOut)
        }
        #expect(start.duration(to: .now) < .seconds(1))

        let rightCrank = locations.supported.first { $0.kind == .rightCrank }!
        do {
            try await locations.update(rightCrank)
            Issue.record("Expected procedureInProgress")
        } catch let error as ControlPointError {
            #expect(error == .procedureInProgress)
        }

        await fake.releaseHungWrite()
        await locations.controlPoint.waitUntilIdle()

        try await locations.update(rightCrank)
        #expect(locations.current.kind == .rightCrank)

        _ = try await connected.disconnect()
    }

    @Test func disconnectFailsInFlightProcedure() async throws {
        let fake = multipleLocationFake()
        let connected = try await CSCClientTestSupport.sensor(central: fake).connect()
        guard case let .multiple(locations) = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }

        await fake.holdNextControlPointIndication()
        let baseline = await CSCClientTestSupport.controlPointWrites(on: fake)
        async let writeRecorded: Void = CSCClientTestSupport.waitForControlPointWrite(
            on: fake,
            after: baseline,
        )
        let updateTask = Task {
            try await locations.update(locations.supported[1])
        }
        await writeRecorded

        let disconnectTask = Task {
            try await connected.disconnect()
        }

        do {
            _ = try await updateTask.value
            Issue.record("Expected update to throw")
        } catch let error as ControlPointError {
            #expect(error == .failed(reason: "Disconnected"))
        }

        _ = try await disconnectTask.value
        await fake.releaseHeldControlPointIndication()
    }

    @Test func disconnectedWriteErrorMapsToDisconnected() async throws {
        let fake = multipleLocationFake()
        let sensorID = UUID()
        let connected = try await CSCClientTestSupport.sensor(id: sensorID, central: fake).connect()
        guard case let .multiple(locations) = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }

        await fake.failNext(.writeValue, with: .disconnected(sensorID, reason: nil))
        do {
            try await locations.update(locations.supported[1])
            Issue.record("Expected disconnected error")
        } catch let error as ControlPointError {
            #expect(error == .failed(reason: "Disconnected"))
        }

        _ = try await connected.disconnect()
    }
}

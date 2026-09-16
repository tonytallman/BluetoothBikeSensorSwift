import BluetoothBikeSensorSwift
import Foundation
import Testing

@Suite struct CSCMeasurementParserTests {
    private let defaultCircumference = 2.105

    private func wheelSample(revolutions: UInt32, eventTime: UInt16) -> CSCMeasurementSample {
        CSCMeasurementParser.parse(
            CSCMeasurementFixtures.wheelMeasurement(revolutions: revolutions, eventTime: eventTime),
        )!
    }

    private func crankSample(revolutions: UInt16, eventTime: UInt16) -> CSCMeasurementSample {
        CSCMeasurementParser.parse(
            CSCMeasurementFixtures.crankMeasurement(revolutions: revolutions, eventTime: eventTime),
        )!
    }

    @Test func parsesWheelOnlyMeasurement() {
        let payload = CSCMeasurementFixtures.wheelMeasurement(
            revolutions: 1_000,
            eventTime: 1_024,
        )

        let sample = CSCMeasurementParser.parse(payload)
        #expect(sample?.cumulativeWheelRevolutions == 1_000)
        #expect(sample?.lastWheelEventTime == 1_024)
        #expect(sample?.cumulativeCrankRevolutions == nil)
    }

    @Test func parsesCrankOnlyMeasurement() {
        let payload = CSCMeasurementFixtures.crankMeasurement(
            revolutions: 500,
            eventTime: 2_048,
        )

        let sample = CSCMeasurementParser.parse(payload)
        #expect(sample?.cumulativeCrankRevolutions == 500)
        #expect(sample?.lastCrankEventTime == 2_048)
        #expect(sample?.cumulativeWheelRevolutions == nil)
    }

    @Test func parsesCombinedMeasurement() {
        let payload = CSCMeasurementFixtures.combinedMeasurement(
            wheelRevolutions: 100,
            wheelEventTime: 1_024,
            crankRevolutions: 80,
            crankEventTime: 2_048,
        )

        let sample = CSCMeasurementParser.parse(payload)
        #expect(sample?.cumulativeWheelRevolutions == 100)
        #expect(sample?.lastWheelEventTime == 1_024)
        #expect(sample?.cumulativeCrankRevolutions == 80)
        #expect(sample?.lastCrankEventTime == 2_048)
    }

    @Test func rejectsShortPayload() {
        #expect(CSCMeasurementParser.parse(Data([0x03])) == nil)
    }

    @Test func wheelDeltaHappyPath() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 100, eventTime: 1_024),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )

        let delta = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 102, eventTime: 2_048),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )

        #expect(delta?.deltaRevolutions == 2)
        #expect(delta?.deltaTimeSeconds == 1.0)
        let speed = CSCMeasurementParser.speed(from: delta!, circumferenceMeters: defaultCircumference)
        #expect(speed.value == 4.21)
        #expect(speed.unit == .metersPerSecond)
    }

    @Test func crankDeltaHappyPath() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 10, eventTime: 1_024),
            previous: &state,
        )

        let delta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 11, eventTime: 2_048),
            previous: &state,
        )

        #expect(delta?.deltaRevolutions == 1)
        #expect(delta?.deltaTimeSeconds == 1.0)
        let cadence = CSCMeasurementParser.cadence(from: delta!)
        #expect(cadence.value == 60.0)
        #expect(cadence.unit == .revolutionsPerMinute)
    }

    @Test func firstPacketSeeds() {
        var state = CSCMeasurementState()

        let wheelDelta = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 100, eventTime: 1_024),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )
        #expect(wheelDelta == nil)
        #expect(state.previousWheelRevolutions == 100)
        #expect(state.previousWheelEventTime == 1_024)

        var crankState = CSCMeasurementState()
        let crankDelta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 10, eventTime: 1_024),
            previous: &crankState,
        )
        #expect(crankDelta == nil)
        #expect(crankState.previousCrankRevolutions == 10)
        #expect(crankState.previousCrankEventTime == 1_024)
    }

    @Test func zeroDeltaTimeDoesNotEmit() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 100, eventTime: 1_024),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )

        let delta = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 101, eventTime: 1_024),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )

        #expect(delta == nil)
        #expect(state.previousWheelRevolutions == 101)
        #expect(state.previousWheelEventTime == 1_024)
    }

    @Test func zeroQuantityWithPositiveDeltaTimeEmitsWheel() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 100, eventTime: 1_024),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )

        let delta = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 100, eventTime: 2_048),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )

        #expect(delta?.deltaRevolutions == 0)
        #expect(delta?.deltaTimeSeconds == 1.0)
        let speed = CSCMeasurementParser.speed(from: delta!, circumferenceMeters: defaultCircumference)
        #expect(speed.value == 0.0)
    }

    @Test func zeroQuantityWithPositiveDeltaTimeEmitsCrank() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 10, eventTime: 1_024),
            previous: &state,
        )

        let delta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 10, eventTime: 2_048),
            previous: &state,
        )

        #expect(delta?.deltaRevolutions == 0)
        #expect(delta?.deltaTimeSeconds == 1.0)
        let cadence = CSCMeasurementParser.cadence(from: delta!)
        #expect(cadence.value == 0.0)
    }

    @Test func handlesWheelRevolutionWraparound() {
        var state = CSCMeasurementState(
            previousWheelRevolutions: UInt32.max - 1,
            previousWheelEventTime: 1_024,
        )

        let delta = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 1, eventTime: 2_048),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )

        #expect(delta?.deltaRevolutions == 3)
        let speed = CSCMeasurementParser.speed(from: delta!, circumferenceMeters: defaultCircumference)
        #expect(abs(speed.value - 6.315) < 0.001)
    }

    @Test func handlesCrankRevolutionWraparound() {
        var state = CSCMeasurementState(
            previousCrankRevolutions: UInt16.max,
            previousCrankEventTime: 1_024,
        )

        let delta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 0, eventTime: 2_048),
            previous: &state,
        )

        #expect(delta?.deltaRevolutions == 1)
        let cadence = CSCMeasurementParser.cadence(from: delta!)
        #expect(abs(cadence.value - 60.0) < 0.001)
    }

    @Test func wheelEventTimeWrapPlausible() {
        var state = CSCMeasurementState(
            previousWheelRevolutions: 100,
            previousWheelEventTime: 65_500,
        )

        let delta = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 101, eventTime: 100),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )

        #expect(delta?.deltaRevolutions == 1)
        let expectedDeltaTime = Double(UInt16(100) &- UInt16(65_500)) / 1024.0
        #expect(abs((delta?.deltaTimeSeconds ?? 0) - expectedDeltaTime) < 0.0001)
        let speed = CSCMeasurementParser.speed(from: delta!, circumferenceMeters: defaultCircumference)
        #expect(abs(speed.value - 15.85) < 0.1)
    }

    @Test func crankEventTimeWrapPlausible() {
        var state = CSCMeasurementState(
            previousCrankRevolutions: 10,
            previousCrankEventTime: 60_000,
        )

        let delta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 11, eventTime: 1_024),
            previous: &state,
        )

        #expect(delta?.deltaRevolutions == 1)
        let expectedDeltaTime = Double(UInt16(1_024) &- UInt16(60_000)) / 1024.0
        #expect(abs((delta?.deltaTimeSeconds ?? 0) - expectedDeltaTime) < 0.0001)
        let cadence = CSCMeasurementParser.cadence(from: delta!)
        #expect(abs(cadence.value - 9.366) < 0.1)
    }

    @Test func crankEventTimeWrapImplausibleRate() {
        var state = CSCMeasurementState(
            previousCrankRevolutions: 10,
            previousCrankEventTime: 65_500,
        )

        let delta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 11, eventTime: 100),
            previous: &state,
        )

        #expect(delta == nil)
        #expect(state.previousCrankRevolutions == 11)
        #expect(state.previousCrankEventTime == 100)
    }

    @Test func wheelImplausibleDeltaReseeds() {
        var state = CSCMeasurementState(
            previousWheelRevolutions: 10_000,
            previousWheelEventTime: 1_024,
        )

        let implausible = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 0, eventTime: 2_048),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )
        #expect(implausible == nil)
        #expect(state.previousWheelRevolutions == 0)

        let followUp = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 2, eventTime: 3_072),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )
        #expect(followUp?.deltaRevolutions == 2)
        let speed = CSCMeasurementParser.speed(from: followUp!, circumferenceMeters: defaultCircumference)
        #expect(abs(speed.value - 4.21) < 0.001)
    }

    @Test func crankImplausibleDeltaReseeds() {
        var state = CSCMeasurementState(
            previousCrankRevolutions: 5_000,
            previousCrankEventTime: 1_024,
        )

        let implausible = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 0, eventTime: 2_048),
            previous: &state,
        )
        #expect(implausible == nil)
        #expect(state.previousCrankRevolutions == 0)

        let followUp = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 1, eventTime: 3_072),
            previous: &state,
        )
        #expect(followUp?.deltaRevolutions == 1)
        let cadence = CSCMeasurementParser.cadence(from: followUp!)
        #expect(cadence.value == 60.0)
    }

    @Test func crankWrapVersusImplausible() {
        var state = CSCMeasurementState(
            previousCrankRevolutions: UInt16.max,
            previousCrankEventTime: 1_024,
        )

        let delta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 1, eventTime: 2_048),
            previous: &state,
        )

        #expect(delta?.deltaRevolutions == 2)
        let cadence = CSCMeasurementParser.cadence(from: delta!)
        #expect(cadence.value == 120.0)
    }

    @Test func crankNearBoundaryWrap() {
        var state = CSCMeasurementState(
            previousCrankRevolutions: UInt16.max - 1,
            previousCrankEventTime: 1_024,
        )

        let delta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 2, eventTime: 2_048),
            previous: &state,
        )

        #expect(delta?.deltaRevolutions == 4)
        let cadence = CSCMeasurementParser.cadence(from: delta!)
        #expect(cadence.value == 240.0)
    }

    @Test func wheelCapExactlyFiftyMetersPerSecondAccepted() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 0, eventTime: 0),
            previous: &state,
            circumferenceMeters: 1.0,
        )

        let delta = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 25, eventTime: 512),
            previous: &state,
            circumferenceMeters: 1.0,
        )

        #expect(delta != nil)
        let speed = CSCMeasurementParser.speed(from: delta!, circumferenceMeters: 1.0)
        #expect(speed.value == 50.0)
    }

    @Test func wheelCapJustOverFiftyRejected() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 0, eventTime: 0),
            previous: &state,
            circumferenceMeters: 1.0,
        )

        let rejected = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 25, eventTime: 511),
            previous: &state,
            circumferenceMeters: 1.0,
        )
        #expect(rejected == nil)

        let followUp = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 26, eventTime: 511 + 1_024),
            previous: &state,
            circumferenceMeters: 1.0,
        )
        #expect(followUp?.deltaRevolutions == 1)
        #expect(followUp?.deltaTimeSeconds == 1.0)
    }

    @Test func crankCapExactlyThreeHundredRPMAccepted() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 0, eventTime: 0),
            previous: &state,
        )

        let delta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 5, eventTime: 1_024),
            previous: &state,
        )

        #expect(delta != nil)
        let cadence = CSCMeasurementParser.cadence(from: delta!)
        #expect(cadence.value == 300.0)
    }

    @Test func crankCapJustOverThreeHundredRejected() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 0, eventTime: 0),
            previous: &state,
        )

        let rejected = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 5, eventTime: 1_023),
            previous: &state,
        )
        #expect(rejected == nil)
    }

    @Test func interleavedPacketsDoNotWipeWheelSeed() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 100, eventTime: 1_024),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )

        _ = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 10, eventTime: 1_024),
            previous: &state,
        )

        let delta = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 102, eventTime: 2_048),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )

        #expect(delta?.deltaRevolutions == 2)
    }

    @Test func interleavedPacketsDoNotWipeCrankSeed() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 10, eventTime: 1_024),
            previous: &state,
        )

        _ = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 100, eventTime: 1_024),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )

        let delta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 11, eventTime: 2_048),
            previous: &state,
        )

        #expect(delta?.deltaRevolutions == 1)
    }

    @Test func crankDeltaIgnoresCircumference() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 10, eventTime: 1_024),
            previous: &state,
        )

        let delta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 11, eventTime: 2_048),
            previous: &state,
        )

        #expect(delta?.deltaRevolutions == 1)
        #expect(delta?.deltaTimeSeconds == 1.0)
    }
}

@Suite struct CSCFeatureParserTests {
    @Test func parsesFeatureCapabilities() {
        let capabilities = CSCFeatureParser.parse(Data([0x01, 0x00]))
        #expect(capabilities?.hasSpeed == true)
        #expect(capabilities?.hasCadence == false)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct CSCMeasurementStreamTests {
    private func makeSensor(
        fake: FakeBluetoothCentral,
        id: UUID = UUID(),
        hasSpeed: Bool = true,
        hasCadence: Bool = true,
    ) -> DiscoveredSensor {
        DiscoveredSensor(
            id: id,
            name: "Test Sensor",
            manufacturer: nil,
            hasSpeed: hasSpeed,
            hasCadence: hasCadence,
            central: fake,
        )
    }

    @Test func connectPreparesMeasurementCharacteristics() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)

        _ = try await sensor.connect()

        let calls = await fake.recordedCalls
        #expect(calls.contains(
            .discoverCharacteristics(
                id: sensorID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUIDs: [CSCS.measurementUUID, CSCS.featureUUID],
            ),
        ))
        #expect(calls.contains(
            .readValue(
                id: sensorID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.featureUUID,
            ),
        ))
        #expect(calls.contains(
            .setNotifyValue(
                id: sensorID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
                enabled: true,
            ),
        ))
    }

    @Test func speedUsesCurrentWheelCircumference() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)
        let connected = try await sensor.connect()
        connected.wheelCircumference = Measurement(value: 2.0, unit: .meters)

        guard let speedStream = await connected.speed else {
            Issue.record("Expected speed stream")
            return
        }

        let collector = Task {
            await AsyncTestHelpers.collect(from: speedStream, maxCount: 1)
        }

        await waitForMeasurementLoop()

        await emitWheelMeasurement(
            fake: fake,
            id: sensorID,
            revolutions: 100,
            eventTime: 1_024,
        )
        await emitWheelMeasurement(
            fake: fake,
            id: sensorID,
            revolutions: 102,
            eventTime: 2_048,
        )

        let speeds = await collector.value
        #expect(speeds.count == 1)
        if speeds.count == 1 {
            #expect(speeds[0].value == 4.0)
        }
    }

    @Test func speedReflectsUpdatedWheelCircumference() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)
        let connected = try await sensor.connect()

        guard let speedStream = await connected.speed else {
            Issue.record("Expected speed stream")
            return
        }

        let collector = Task {
            await AsyncTestHelpers.collect(from: speedStream, maxCount: 2)
        }

        await waitForMeasurementLoop()

        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 100, eventTime: 1_024)
        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 102, eventTime: 2_048)

        connected.wheelCircumference = Measurement(value: 1.0, unit: .meters)

        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 104, eventTime: 3_072)
        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 106, eventTime: 4_096)

        let speeds = await collector.value
        #expect(speeds.count == 2)
        if speeds.count == 2 {
            #expect(speeds[0].value == 4.21)
            #expect(speeds[1].value == 2.0)
        }
    }

    @Test func cadenceOnlySensorHasNilSpeedAndWheelSamples() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(Data([0x02, 0x00]))

        let connected = try await makeSensor(fake: fake, hasSpeed: false, hasCadence: true).connect()
        #expect(await connected.speed == nil)
        #expect(await connected.cadence != nil)
        #expect(await connected.wheelSamples == nil)
        #expect(await connected.crankSamples != nil)
    }

    @Test func speedOnlySensorHasNilCadenceAndCrankSamples() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(Data([0x01, 0x00]))

        let connected = try await makeSensor(fake: fake, hasSpeed: true, hasCadence: false).connect()
        #expect(await connected.speed != nil)
        #expect(await connected.cadence == nil)
        #expect(await connected.wheelSamples != nil)
        #expect(await connected.crankSamples == nil)
    }

    @Test func wheelSamplesEmitAfterTwoNotifies() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let connected = try await makeSensor(fake: fake, id: sensorID).connect()
        connected.wheelCircumference = Measurement(value: 2.0, unit: .meters)

        guard let stream = await connected.wheelSamples else {
            Issue.record("Expected wheelSamples stream")
            return
        }

        let collector = Task {
            await AsyncTestHelpers.collectUntil(from: stream, maxCount: 1)
        }

        await waitForMeasurementLoop()

        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 100, eventTime: 1_024)
        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 102, eventTime: 2_048)

        let samples = await collector.value
        #expect(samples.count == 1)
        if samples.count == 1 {
            #expect(samples[0].deltaDistance.converted(to: .meters).value == 4.0)
            #expect(samples[0].deltaTime.converted(to: .seconds).value == 1.0)
        }
    }

    @Test func wheelSamplesReflectUpdatedCircumference() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let connected = try await makeSensor(fake: fake, id: sensorID).connect()

        guard let stream = await connected.wheelSamples else {
            Issue.record("Expected wheelSamples stream")
            return
        }

        let collector = Task {
            await AsyncTestHelpers.collectUntil(from: stream, maxCount: 2)
        }

        await waitForMeasurementLoop()

        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 100, eventTime: 1_024)
        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 102, eventTime: 2_048)

        connected.wheelCircumference = Measurement(value: 1.0, unit: .meters)

        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 104, eventTime: 3_072)
        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 106, eventTime: 4_096)

        let samples = await collector.value
        #expect(samples.count == 2)
        if samples.count == 2 {
            #expect(samples[0].deltaDistance.converted(to: .meters).value == 4.21)
            #expect(samples[1].deltaDistance.converted(to: .meters).value == 2.0)
        }
    }

    @Test func crankSamplesEmitAfterTwoNotifies() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let connected = try await makeSensor(fake: fake, id: sensorID).connect()

        guard let stream = await connected.crankSamples else {
            Issue.record("Expected crankSamples stream")
            return
        }

        let collector = Task {
            await AsyncTestHelpers.collectUntil(from: stream, maxCount: 1)
        }

        await waitForMeasurementLoop()

        await emitCrankMeasurement(fake: fake, id: sensorID, revolutions: 10, eventTime: 1_024)
        await emitCrankMeasurement(fake: fake, id: sensorID, revolutions: 11, eventTime: 2_048)

        let samples = await collector.value
        #expect(samples.count == 1)
        if samples.count == 1 {
            #expect(samples[0].deltaRevolutions == 1)
            #expect(samples[0].deltaTime.converted(to: .seconds).value == 1.0)
        }
    }

    @Test func combinedPayloadEmitsBothSamples() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let connected = try await makeSensor(fake: fake, id: sensorID).connect()

        guard let wheelStream = await connected.wheelSamples,
              let crankStream = await connected.crankSamples
        else {
            Issue.record("Expected both sample streams")
            return
        }

        let wheelCollector = Task {
            await AsyncTestHelpers.collectUntil(from: wheelStream, maxCount: 1)
        }
        let crankCollector = Task {
            await AsyncTestHelpers.collectUntil(from: crankStream, maxCount: 1)
        }

        await waitForMeasurementLoop()

        await emitCombinedMeasurement(
            fake: fake,
            id: sensorID,
            wheelRevolutions: 100,
            wheelEventTime: 1_024,
            crankRevolutions: 10,
            crankEventTime: 1_024,
        )
        await emitCombinedMeasurement(
            fake: fake,
            id: sensorID,
            wheelRevolutions: 102,
            wheelEventTime: 2_048,
            crankRevolutions: 11,
            crankEventTime: 2_048,
        )

        let wheelSamples = await wheelCollector.value
        let crankSamples = await crankCollector.value
        #expect(wheelSamples.count == 1)
        #expect(crankSamples.count == 1)
    }

    @Test func combinedPayloadOneSideIdle() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let connected = try await makeSensor(fake: fake, id: sensorID).connect()

        guard let wheelStream = await connected.wheelSamples,
              let crankStream = await connected.crankSamples,
              let speedStream = await connected.speed,
              let cadenceStream = await connected.cadence
        else {
            Issue.record("Expected all streams")
            return
        }

        let wheelCollector = Task {
            await AsyncTestHelpers.collectUntil(from: wheelStream, maxCount: 1)
        }
        let crankCollector = Task {
            await AsyncTestHelpers.collectUntil(from: crankStream, maxCount: 1)
        }
        let speedCollector = Task {
            await AsyncTestHelpers.collectUntil(from: speedStream, maxCount: 1)
        }
        let cadenceCollector = Task {
            await AsyncTestHelpers.collectUntil(from: cadenceStream, maxCount: 1)
        }

        await waitForMeasurementLoop()

        await emitCombinedMeasurement(
            fake: fake,
            id: sensorID,
            wheelRevolutions: 100,
            wheelEventTime: 1_024,
            crankRevolutions: 10,
            crankEventTime: 1_024,
        )
        await emitCombinedMeasurement(
            fake: fake,
            id: sensorID,
            wheelRevolutions: 102,
            wheelEventTime: 2_048,
            crankRevolutions: 10,
            crankEventTime: 1_024,
        )

        let wheelSamples = await wheelCollector.value
        let crankSamples = await crankCollector.value
        let speeds = await speedCollector.value
        let cadences = await cadenceCollector.value

        #expect(wheelSamples.count == 1)
        #expect(crankSamples.isEmpty)
        #expect(speeds.count == 1)
        #expect(cadences.isEmpty)
    }

    @Test func crossStreamWheelConsistency() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let connected = try await makeSensor(fake: fake, id: sensorID).connect()

        guard let speedStream = await connected.speed,
              let wheelStream = await connected.wheelSamples
        else {
            Issue.record("Expected speed and wheelSamples streams")
            return
        }

        let speedCollector = Task {
            await AsyncTestHelpers.collectUntil(from: speedStream, maxCount: 1)
        }
        let wheelCollector = Task {
            await AsyncTestHelpers.collectUntil(from: wheelStream, maxCount: 1)
        }

        await waitForMeasurementLoop()

        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 100, eventTime: 1_024)
        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 102, eventTime: 2_048)

        let speeds = await speedCollector.value
        let samples = await wheelCollector.value

        #expect(speeds.count == 1)
        #expect(samples.count == 1)
        if speeds.count == 1, samples.count == 1 {
            let distanceMeters = samples[0].deltaDistance.converted(to: .meters).value
            let timeSeconds = samples[0].deltaTime.converted(to: .seconds).value
            let impliedSpeed = distanceMeters / timeSeconds
            #expect(abs(speeds[0].converted(to: .metersPerSecond).value - impliedSpeed) < 0.001)
        }
    }

    @Test func crossStreamCrankConsistency() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let connected = try await makeSensor(fake: fake, id: sensorID).connect()

        guard let cadenceStream = await connected.cadence,
              let crankStream = await connected.crankSamples
        else {
            Issue.record("Expected cadence and crankSamples streams")
            return
        }

        let cadenceCollector = Task {
            await AsyncTestHelpers.collectUntil(from: cadenceStream, maxCount: 1)
        }
        let crankCollector = Task {
            await AsyncTestHelpers.collectUntil(from: crankStream, maxCount: 1)
        }

        await waitForMeasurementLoop()

        await emitCrankMeasurement(fake: fake, id: sensorID, revolutions: 10, eventTime: 1_024)
        await emitCrankMeasurement(fake: fake, id: sensorID, revolutions: 11, eventTime: 2_048)

        let cadences = await cadenceCollector.value
        let samples = await crankCollector.value

        #expect(cadences.count == 1)
        #expect(samples.count == 1)
        if cadences.count == 1, samples.count == 1 {
            let timeSeconds = samples[0].deltaTime.converted(to: .seconds).value
            let impliedCadence = (Double(samples[0].deltaRevolutions) / timeSeconds) * 60.0
            #expect(abs(cadences[0].value - impliedCadence) < 0.001)
        }
    }

    @Test func disconnectFinishesAllStreams() async throws {
        let fake = FakeBluetoothCentral()
        let sensor = makeSensor(fake: fake)
        let connected = try await sensor.connect()

        guard let speedStream = await connected.speed,
              let wheelStream = await connected.wheelSamples
        else {
            Issue.record("Expected streams")
            return
        }

        let speedCollector = Task {
            var finished = false
            for await _ in speedStream {
            }
            finished = true
            return finished
        }
        let wheelCollector = Task {
            var finished = false
            for await _ in wheelStream {
            }
            finished = true
            return finished
        }

        _ = try await connected.disconnect()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let speedFinished = await speedCollector.value
        let wheelFinished = await wheelCollector.value
        #expect(speedFinished == true)
        #expect(wheelFinished == true)
    }

    @Test func unexpectedDisconnectFinishesAllStreams() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)
        let connected = try await sensor.connect()

        guard let cadenceStream = await connected.cadence,
              let crankStream = await connected.crankSamples
        else {
            Issue.record("Expected streams")
            return
        }

        await waitForMeasurementLoop()

        let cadenceCollector = Task {
            var finished = false
            for await _ in cadenceStream {
            }
            finished = true
            return finished
        }
        let crankCollector = Task {
            var finished = false
            for await _ in crankStream {
            }
            finished = true
            return finished
        }

        await fake.emitConnection(.disconnected(id: sensorID, reason: "Link lost"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        let cadenceFinished = await cadenceCollector.value
        let crankFinished = await crankCollector.value
        #expect(cadenceFinished == true)
        #expect(crankFinished == true)
    }

    @Test func cadenceStreamEmitsRPMValues() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)
        let connected = try await sensor.connect()

        guard let cadenceStream = await connected.cadence else {
            Issue.record("Expected cadence stream")
            return
        }

        let collector = Task {
            await AsyncTestHelpers.collect(from: cadenceStream, maxCount: 1)
        }

        await waitForMeasurementLoop()

        await emitCrankMeasurement(
            fake: fake,
            id: sensorID,
            revolutions: 10,
            eventTime: 1_024,
        )
        await emitCrankMeasurement(
            fake: fake,
            id: sensorID,
            revolutions: 11,
            eventTime: 2_048,
        )

        let cadences = await collector.value
        #expect(cadences.count == 1)
        if cadences.count == 1 {
            #expect(cadences[0].value == 60.0)
            #expect(cadences[0].unit == .revolutionsPerMinute)
        }
    }

    @Test func unexpectedDisconnectFinishesStreamsAfterEmission() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)
        let connected = try await sensor.connect()

        guard let speedStream = await connected.speed else {
            Issue.record("Expected speed stream")
            return
        }

        await waitForMeasurementLoop()

        let collector = Task { () -> (speeds: [Speed], finished: Bool) in
            var speeds: [Speed] = []
            for await speed in speedStream {
                speeds.append(speed)
            }
            return (speeds, true)
        }

        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 100, eventTime: 1_024)
        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 102, eventTime: 2_048)

        try? await Task.sleep(nanoseconds: 150_000_000)

        await fake.emitConnection(.disconnected(id: sensorID, reason: "Link lost"))
        try? await Task.sleep(nanoseconds: 100_000_000)

        let result = await collector.value
        #expect(result.speeds.count == 1)
        #expect(result.finished == true)
    }

    @Test func notifyFailureMapsToConnectError() async {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)

        await fake.failNextSetNotify(
            with: .characteristicNotFound(
                sensorID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )

        do {
            _ = try await sensor.connect()
            Issue.record("Expected connect to throw")
        } catch let error as ConnectError {
            #expect(error == .serviceDiscoveryFailed(
                reason: "Characteristic not found: \(CSCS.measurementUUID) on \(CSCS.serviceUUID)",
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func emitCombinedMeasurement(
        fake: FakeBluetoothCentral,
        id: UUID,
        wheelRevolutions: UInt32,
        wheelEventTime: UInt16,
        crankRevolutions: UInt16,
        crankEventTime: UInt16,
    ) async {
        let payload = CSCMeasurementFixtures.combinedMeasurement(
            wheelRevolutions: wheelRevolutions,
            wheelEventTime: wheelEventTime,
            crankRevolutions: crankRevolutions,
            crankEventTime: crankEventTime,
        )
        await fake.emitGATT(
            .characteristicValue(
                id: id,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
                value: payload,
            ),
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func emitCrankMeasurement(
        fake: FakeBluetoothCentral,
        id: UUID,
        revolutions: UInt16,
        eventTime: UInt16,
    ) async {
        let payload = CSCMeasurementFixtures.crankMeasurement(
            revolutions: revolutions,
            eventTime: eventTime,
        )
        await fake.emitGATT(
            .characteristicValue(
                id: id,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
                value: payload,
            ),
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func emitWheelMeasurement(
        fake: FakeBluetoothCentral,
        id: UUID,
        revolutions: UInt32,
        eventTime: UInt16,
    ) async {
        let payload = CSCMeasurementFixtures.wheelMeasurement(
            revolutions: revolutions,
            eventTime: eventTime,
        )
        await fake.emitGATT(
            .characteristicValue(
                id: id,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
                value: payload,
            ),
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func waitForMeasurementLoop() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
}

enum CSCMeasurementFixtures {
    static func wheelMeasurement(revolutions: UInt32, eventTime: UInt16) -> Data {
        var data = Data([0x01])
        data.append(contentsOf: encodeUInt32LE(revolutions))
        data.append(contentsOf: encodeUInt16LE(eventTime))
        return data
    }

    static func crankMeasurement(revolutions: UInt16, eventTime: UInt16) -> Data {
        var data = Data([0x02])
        data.append(contentsOf: encodeUInt16LE(revolutions))
        data.append(contentsOf: encodeUInt16LE(eventTime))
        return data
    }

    static func combinedMeasurement(
        wheelRevolutions: UInt32,
        wheelEventTime: UInt16,
        crankRevolutions: UInt16,
        crankEventTime: UInt16,
    ) -> Data {
        var data = Data([0x03])
        data.append(contentsOf: encodeUInt32LE(wheelRevolutions))
        data.append(contentsOf: encodeUInt16LE(wheelEventTime))
        data.append(contentsOf: encodeUInt16LE(crankRevolutions))
        data.append(contentsOf: encodeUInt16LE(crankEventTime))
        return data
    }

    private static func encodeUInt16LE(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private static func encodeUInt32LE(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8(value >> 24),
        ]
    }
}

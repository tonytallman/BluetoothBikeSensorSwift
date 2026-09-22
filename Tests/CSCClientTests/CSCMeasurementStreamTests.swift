import CSCClient
import CSCWire
import Foundation
import Testing

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
                characteristicUUIDs: ConnectedSensorTestHelpers.allCSCCharacteristicUUIDs,
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
        guard let wheel = ConnectedSensorTestHelpers.wheel(from: connected) else {
            Issue.record("Expected wheel revolutions")
            return
        }
        wheel.wheelCircumference = Measurement(value: 2.0, unit: .meters)

        let speedStream = await wheel.speed

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
        guard let wheel = ConnectedSensorTestHelpers.wheel(from: connected) else {
            Issue.record("Expected wheel revolutions")
            return
        }

        let speedStream = await wheel.speed

        let collector = Task {
            await AsyncTestHelpers.collect(from: speedStream, maxCount: 2)
        }

        await waitForMeasurementLoop()

        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 100, eventTime: 1_024)
        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 102, eventTime: 2_048)

        wheel.wheelCircumference = Measurement(value: 1.0, unit: .meters)

        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 104, eventTime: 3_072)
        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 106, eventTime: 4_096)

        let speeds = await collector.value
        #expect(speeds.count == 2)
        if speeds.count == 2 {
            #expect(speeds[0].value == 4.21)
            #expect(speeds[1].value == 2.0)
        }
    }

    @Test func cadenceOnlySensorHasNoWheelStreams() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(CSCFeature([.crankRevolutionData]).encode())

        let connected = try await makeSensor(fake: fake).connect()
        switch connected.revolutions {
        case .crank:
            break
        default:
            Issue.record("Expected crank-only revolution data")
        }
        #expect(ConnectedSensorTestHelpers.wheel(from: connected) == nil)
        #expect(ConnectedSensorTestHelpers.crank(from: connected) != nil)
    }

    @Test func speedOnlySensorHasNoCrankStreams() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(CSCFeature([.wheelRevolutionData]).encode())

        let connected = try await makeSensor(fake: fake).connect()
        switch connected.revolutions {
        case .wheel:
            break
        default:
            Issue.record("Expected wheel-only revolution data")
        }
        #expect(ConnectedSensorTestHelpers.wheel(from: connected) != nil)
        #expect(ConnectedSensorTestHelpers.crank(from: connected) == nil)
    }

    @Test func wheelSamplesEmitAfterTwoNotifies() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let connected = try await makeSensor(fake: fake, id: sensorID).connect()
        guard let wheel = ConnectedSensorTestHelpers.wheel(from: connected) else {
            Issue.record("Expected wheel revolutions")
            return
        }
        wheel.wheelCircumference = Measurement(value: 2.0, unit: .meters)

        let stream = await wheel.wheelSamples

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
        guard let wheel = ConnectedSensorTestHelpers.wheel(from: connected) else {
            Issue.record("Expected wheel revolutions")
            return
        }

        let stream = await wheel.wheelSamples

        let collector = Task {
            await AsyncTestHelpers.collectUntil(from: stream, maxCount: 2)
        }

        await waitForMeasurementLoop()

        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 100, eventTime: 1_024)
        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 102, eventTime: 2_048)

        wheel.wheelCircumference = Measurement(value: 1.0, unit: .meters)

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

        guard let crank = ConnectedSensorTestHelpers.crank(from: connected) else {
            Issue.record("Expected crank revolutions")
            return
        }

        let stream = await crank.crankSamples

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

        guard let wheel = ConnectedSensorTestHelpers.wheel(from: connected),
              let crank = ConnectedSensorTestHelpers.crank(from: connected)
        else {
            Issue.record("Expected both sample streams")
            return
        }

        let wheelStream = await wheel.wheelSamples
        let crankStream = await crank.crankSamples

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
        if wheelSamples.count == 1, crankSamples.count == 1 {
            #expect(wheelSamples[0].deltaDistance.converted(to: .meters).value == 4.21)
            #expect(wheelSamples[0].deltaTime.converted(to: .seconds).value == 1.0)
            #expect(crankSamples[0].deltaRevolutions == 1)
            #expect(crankSamples[0].deltaTime.converted(to: .seconds).value == 1.0)
        }
    }

    @Test func interleavedPacketsEmitBothFamilies() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let connected = try await makeSensor(fake: fake, id: sensorID).connect()

        guard let wheel = ConnectedSensorTestHelpers.wheel(from: connected),
              let crank = ConnectedSensorTestHelpers.crank(from: connected)
        else {
            Issue.record("Expected both sample streams")
            return
        }

        let wheelStream = await wheel.wheelSamples
        let crankStream = await crank.crankSamples

        let wheelCollector = Task {
            await AsyncTestHelpers.collectUntil(from: wheelStream, maxCount: 1)
        }
        let crankCollector = Task {
            await AsyncTestHelpers.collectUntil(from: crankStream, maxCount: 1)
        }

        await waitForMeasurementLoop()

        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 100, eventTime: 1_024)
        await emitCrankMeasurement(fake: fake, id: sensorID, revolutions: 10, eventTime: 1_024)
        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 102, eventTime: 2_048)
        await emitCrankMeasurement(fake: fake, id: sensorID, revolutions: 11, eventTime: 2_048)

        let wheelSamples = await wheelCollector.value
        let crankSamples = await crankCollector.value
        #expect(wheelSamples.count == 1)
        #expect(crankSamples.count == 1)
        if wheelSamples.count == 1, crankSamples.count == 1 {
            #expect(wheelSamples[0].deltaDistance.converted(to: .meters).value == 4.21)
            #expect(wheelSamples[0].deltaTime.converted(to: .seconds).value == 1.0)
            #expect(crankSamples[0].deltaRevolutions == 1)
            #expect(crankSamples[0].deltaTime.converted(to: .seconds).value == 1.0)
        }
    }

    @Test func combinedPayloadOneSideIdle() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let connected = try await makeSensor(fake: fake, id: sensorID).connect()

        guard let wheel = ConnectedSensorTestHelpers.wheel(from: connected),
              let crank = ConnectedSensorTestHelpers.crank(from: connected)
        else {
            Issue.record("Expected all streams")
            return
        }

        let wheelStream = await wheel.wheelSamples
        let crankStream = await crank.crankSamples
        let speedStream = await wheel.speed
        let cadenceStream = await crank.cadence

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

        guard let wheel = ConnectedSensorTestHelpers.wheel(from: connected) else {
            Issue.record("Expected wheel revolutions")
            return
        }

        let speedStream = await wheel.speed
        let wheelStream = await wheel.wheelSamples

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

        guard let crank = ConnectedSensorTestHelpers.crank(from: connected) else {
            Issue.record("Expected crank revolutions")
            return
        }

        let cadenceStream = await crank.cadence
        let crankStream = await crank.crankSamples

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

        guard let wheel = ConnectedSensorTestHelpers.wheel(from: connected),
              let crank = ConnectedSensorTestHelpers.crank(from: connected)
        else {
            Issue.record("Expected streams")
            return
        }

        let speedStream = await wheel.speed
        let cadenceStream = await crank.cadence
        let wheelStream = await wheel.wheelSamples
        let crankStream = await crank.crankSamples

        let speedCollector = Task {
            var finished = false
            for await _ in speedStream {
            }
            finished = true
            return finished
        }
        let cadenceCollector = Task {
            var finished = false
            for await _ in cadenceStream {
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
        let crankCollector = Task {
            var finished = false
            for await _ in crankStream {
            }
            finished = true
            return finished
        }

        _ = try await connected.disconnect()
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(await speedCollector.value == true)
        #expect(await cadenceCollector.value == true)
        #expect(await wheelCollector.value == true)
        #expect(await crankCollector.value == true)
    }

    @Test func unexpectedDisconnectFinishesAllStreams() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)
        let connected = try await sensor.connect()

        guard let wheel = ConnectedSensorTestHelpers.wheel(from: connected),
              let crank = ConnectedSensorTestHelpers.crank(from: connected)
        else {
            Issue.record("Expected streams")
            return
        }

        let speedStream = await wheel.speed
        let cadenceStream = await crank.cadence
        let wheelStream = await wheel.wheelSamples
        let crankStream = await crank.crankSamples

        await waitForMeasurementLoop()

        let speedCollector = Task {
            var finished = false
            for await _ in speedStream {
            }
            finished = true
            return finished
        }
        let cadenceCollector = Task {
            var finished = false
            for await _ in cadenceStream {
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
        let crankCollector = Task {
            var finished = false
            for await _ in crankStream {
            }
            finished = true
            return finished
        }

        await fake.emitConnection(.disconnected(id: sensorID, reason: "Link lost"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(await speedCollector.value == true)
        #expect(await cadenceCollector.value == true)
        #expect(await wheelCollector.value == true)
        #expect(await crankCollector.value == true)
    }

    @Test func cadenceStreamEmitsRPMValues() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)
        let connected = try await sensor.connect()

        guard let crank = ConnectedSensorTestHelpers.crank(from: connected) else {
            Issue.record("Expected crank revolutions")
            return
        }

        let cadenceStream = await crank.cadence

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

        guard let wheel = ConnectedSensorTestHelpers.wheel(from: connected) else {
            Issue.record("Expected wheel revolutions")
            return
        }

        let speedStream = await wheel.speed

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


@testable import BluetoothBikeSensorSwift
import Foundation
import Testing

@Suite struct CSCMeasurementParserTests {
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

    @Test func computesSpeedFromWheelDelta() {
        var state = CSCMeasurementState()
        let first = CSCMeasurementFixtures.wheelMeasurement(revolutions: 100, eventTime: 1_024)
        let second = CSCMeasurementFixtures.wheelMeasurement(revolutions: 102, eventTime: 2_048)

        _ = CSCMeasurementParser.speed(
            from: CSCMeasurementParser.parse(first)!,
            previous: &state,
            circumferenceMeters: 2.105,
        )

        let speed = CSCMeasurementParser.speed(
            from: CSCMeasurementParser.parse(second)!,
            previous: &state,
            circumferenceMeters: 2.105,
        )

        #expect(speed?.value == 4.21)
        #expect(speed?.unit == .metersPerSecond)
    }

    @Test func computesCadenceFromCrankDelta() {
        var state = CSCMeasurementState()
        let first = CSCMeasurementFixtures.crankMeasurement(revolutions: 10, eventTime: 1_024)
        let second = CSCMeasurementFixtures.crankMeasurement(revolutions: 11, eventTime: 2_048)

        _ = CSCMeasurementParser.cadence(
            from: CSCMeasurementParser.parse(first)!,
            previous: &state,
        )

        let cadence = CSCMeasurementParser.cadence(
            from: CSCMeasurementParser.parse(second)!,
            previous: &state,
        )

        #expect(cadence?.value == 60.0)
        #expect(cadence?.unit == .revolutionsPerMinute)
    }

    @Test func handlesWheelRevolutionWraparound() {
        var state = CSCMeasurementState(
            previousWheelRevolutions: UInt32.max - 1,
            previousWheelEventTime: 1_024,
        )
        let sample = CSCMeasurementFixtures.wheelMeasurement(revolutions: 1, eventTime: 2_048)

        let speed = CSCMeasurementParser.speed(
            from: CSCMeasurementParser.parse(sample)!,
            previous: &state,
            circumferenceMeters: 2.105,
        )

        #expect(abs((speed?.value ?? 0) - 6.315) < 0.001)
    }
}

@Suite struct CSCFeatureParserTests {
    @Test func parsesFeatureCapabilities() {
        let capabilities = CSCFeatureParser.parse(Data([0x01, 0x00]))
        #expect(capabilities?.hasSpeed == true)
        #expect(capabilities?.hasCadence == false)
    }
}

@Suite struct CSCMeasurementStreamTests {
    private func makeSensor(
        fake: FakeBluetoothCentral,
        id: UUID = UUID(),
    ) -> DiscoveredSensor {
        DiscoveredSensor(
            id: id,
            name: "Test Sensor",
            manufacturer: nil,
            hasSpeed: true,
            hasCadence: true,
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

        guard let speedStream = connected.speed else {
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

        guard let speedStream = connected.speed else {
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

    @Test func cadenceOnlySensorHasNilSpeedStream() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(Data([0x02, 0x00]))

        let connected = try await makeSensor(fake: fake).connect()
        #expect(connected.speed == nil)
        #expect(connected.cadence != nil)
    }

    @Test func disconnectFinishesStreams() async throws {
        let fake = FakeBluetoothCentral()
        let sensor = makeSensor(fake: fake)
        let connected = try await sensor.connect()

        guard let speedStream = connected.speed else {
            Issue.record("Expected speed stream")
            return
        }

        let collector = Task {
            var finished = false
            for await _ in speedStream {
            }
            finished = true
            return finished
        }

        _ = try await connected.disconnect()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let finished = await collector.value
        #expect(finished == true)
    }

    @Test func unexpectedDisconnectFinishesStreams() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)
        let connected = try await sensor.connect()

        guard let cadenceStream = connected.cadence else {
            Issue.record("Expected cadence stream")
            return
        }

        await waitForMeasurementLoop()

        let collector = Task {
            var finished = false
            for await _ in cadenceStream {
            }
            finished = true
            return finished
        }

        await fake.emitConnection(.disconnected(id: sensorID, reason: "Link lost"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        let finished = await collector.value
        #expect(finished == true)
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

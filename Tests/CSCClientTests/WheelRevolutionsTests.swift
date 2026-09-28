import CSCClient
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct WheelRevolutionsTests {
    @Test func speedUsesCurrentWheelCircumference() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let connected = try await CSCClientTestSupport.sensor(id: sensorID, central: fake).connect()
        let wheel = try #require(connected.revolutions.wheel)
        wheel.wheelCircumference = Measurement(value: 2.0, unit: .meters)

        var speedIterator = (await wheel.speed).makeAsyncIterator()
        var sampleIterator = (await wheel.wheelSamples).makeAsyncIterator()

        await emitWheel(fake: fake, id: sensorID, revolutions: 100, eventTime: 1_024)
        await emitWheel(fake: fake, id: sensorID, revolutions: 102, eventTime: 2_048)

        let speed = await speedIterator.next()
        let sample = await sampleIterator.next()
        #expect(speed?.value == 4.0)
        #expect(sample?.deltaDistance.converted(to: .meters).value == 4.0)
        #expect(sample?.deltaTime.converted(to: .seconds).value == 1.0)
        if let speed, let sample {
            let implied = sample.deltaDistance.converted(to: .meters).value
                / sample.deltaTime.converted(to: .seconds).value
            #expect(abs(speed.converted(to: .metersPerSecond).value - implied) < 0.001)
        }
    }

    @Test func speedReflectsUpdatedWheelCircumference() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let connected = try await CSCClientTestSupport.sensor(id: sensorID, central: fake).connect()
        let wheel = try #require(connected.revolutions.wheel)

        var speedIterator = (await wheel.speed).makeAsyncIterator()
        var sampleIterator = (await wheel.wheelSamples).makeAsyncIterator()

        await emitWheel(fake: fake, id: sensorID, revolutions: 100, eventTime: 1_024)
        await emitWheel(fake: fake, id: sensorID, revolutions: 102, eventTime: 2_048)
        let firstSpeed = await speedIterator.next()
        let firstSample = await sampleIterator.next()
        #expect(firstSpeed?.value == 4.21)
        #expect(firstSample?.deltaDistance.converted(to: .meters).value == 4.21)

        wheel.wheelCircumference = Measurement(value: 1.0, unit: .meters)
        await emitWheel(fake: fake, id: sensorID, revolutions: 104, eventTime: 3_072)
        await emitWheel(fake: fake, id: sensorID, revolutions: 106, eventTime: 4_096)

        let secondSpeed = await speedIterator.next()
        let secondSample = await sampleIterator.next()
        #expect(secondSpeed?.value == 2.0)
        #expect(secondSample?.deltaDistance.converted(to: .meters).value == 2.0)
    }

    @Test func setCumulativeRevolutionsClearsBaseline() async throws {
        let fake = FakeBluetoothCentral(
            discoveredCharacteristicUUIDs: FakeCharacteristicSets.wheelAndControlPointCharacteristics(),
        )
        let sensorID = UUID()
        let connected = try await CSCClientTestSupport.sensor(id: sensorID, central: fake).connect()
        let wheel = try #require(connected.revolutions.wheel)

        var sampleIterator = (await wheel.wheelSamples).makeAsyncIterator()

        await emitWheel(fake: fake, id: sensorID, revolutions: 100, eventTime: 1_024)
        try await wheel.setCumulativeRevolutions(0)
        await emitWheel(fake: fake, id: sensorID, revolutions: 101, eventTime: 1_536)
        await emitWheel(fake: fake, id: sensorID, revolutions: 103, eventTime: 2_560)

        let calls = await fake.recordedCalls
        #expect(calls.contains { call in
            guard case let .writeValue(
                _,
                serviceUUID,
                characteristicUUID,
                value,
            ) = call else {
                return false
            }
            return serviceUUID == CSCS.serviceUUID
                && characteristicUUID == CSCS.controlPointUUID
                && value.first == CSCControlPointOpCode.setCumulativeValue.rawValue
        })

        let sample = await sampleIterator.next()
        #expect(sample?.deltaTime.converted(to: .seconds).value == 1.0)
    }

    @Test func setCumulativeRevolutionsThrowsWhenControlPointMissing() async throws {
        let fake = FakeBluetoothCentral(
            featureData: CSCFeature([.wheelRevolutionData]).encode(),
            discoveredCharacteristicUUIDs: FakeCharacteristicSets.crankOnlyCharacteristics(),
        )
        let connected = try await CSCClientTestSupport.sensor(central: fake).connect()
        let wheel = try #require(connected.revolutions.wheel)

        do {
            try await wheel.setCumulativeRevolutions(0)
            Issue.record("Expected controlPointUnavailable")
        } catch let error as ControlPointError {
            #expect(error == .controlPointUnavailable)
        }

        #expect(await CSCClientTestSupport.controlPointWrites(on: fake) == 0)
    }

    @Test(arguments: ["setCumulativeRevolutionsMapsOpCodeNotSupported", "setCumulativeRevolutionsMapsOperationFailed"])
    func setCumulativeRevolutionsMapsResponse(caseName: String) async throws {
        let fake = FakeBluetoothCentral(
            discoveredCharacteristicUUIDs: FakeCharacteristicSets.wheelAndControlPointCharacteristics(),
        )
        let connected = try await CSCClientTestSupport.sensor(central: fake).connect()
        let wheel = try #require(connected.revolutions.wheel)

        switch caseName {
        case "setCumulativeRevolutionsMapsOpCodeNotSupported":
            await fake.setNextControlPointResponseValue(0x02)
            do {
                try await wheel.setCumulativeRevolutions(0)
                Issue.record("Expected opCodeNotSupported")
            } catch let error as ControlPointError {
                #expect(error == .opCodeNotSupported)
            }
        case "setCumulativeRevolutionsMapsOperationFailed":
            await fake.setNextControlPointResponseValue(0x04)
            do {
                try await wheel.setCumulativeRevolutions(0)
                Issue.record("Expected operationFailed")
            } catch let error as ControlPointError {
                #expect(error == .operationFailed)
            }
        default:
            Issue.record("Unknown case")
        }
    }

    @Test(arguments: [
        ("wheelDeltaHappyPath", 2, 1.0, 4.21),
        ("zeroQuantityWithPositiveDeltaTimeEmitsWheel", 0, 1.0, 0.0),
        ("handlesWheelRevolutionWraparound", 3, 1.0, 6.315),
        ("wheelEventTimeWrapPlausible", 1, Double(UInt16(100) &- UInt16(65_500)) / 1024.0, 15.85),
        ("wheelCapExactlyFiftyMetersPerSecondAccepted", 50, 2.105, 50.0),
    ] as [(String, UInt32, Double, Double)])
    func wheelSampleMath(
        caseName: String,
        deltaRevolutions: UInt32,
        deltaSeconds: Double,
        expectedSpeed: Double,
    ) {
        let circumference = caseName == "wheelCapExactlyFiftyMetersPerSecondAccepted" ? 2.105 : 2.105
        let sample = WheelRevolutions.sample(
            revolutions: deltaRevolutions,
            seconds: deltaSeconds,
            circumferenceMeters: circumference,
        )
        #expect(sample != nil)
        if let sample {
            let speed = sample.deltaDistance.converted(to: .meters).value / sample.deltaTime.converted(to: .seconds).value
            #expect(abs(speed - expectedSpeed) < (caseName == "wheelEventTimeWrapPlausible" ? 0.1 : 0.01))
        }
    }

    @Test(arguments: ["wheelImplausibleDeltaReseeds", "wheelCapJustOverFiftyRejected"])
    func implausibleWheelDeltaIsDroppedAndReseeds(caseName: String) async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let connected = try await CSCClientTestSupport.sensor(id: sensorID, central: fake).connect()
        let wheel = try #require(connected.revolutions.wheel)

        var iterator = (await wheel.wheelSamples).makeAsyncIterator()

        if caseName == "wheelImplausibleDeltaReseeds" {
            await emitWheel(fake: fake, id: sensorID, revolutions: 100, eventTime: 1_024)
            await emitWheel(fake: fake, id: sensorID, revolutions: 10_000, eventTime: 2_048)
            await emitWheel(fake: fake, id: sensorID, revolutions: 10_001, eventTime: 3_072)
            let sample = await iterator.next()
            #expect(sample?.deltaTime.converted(to: .seconds).value == 1.0)
            #expect(sample?.deltaDistance.converted(to: .meters).value == 2.105)
        } else {
            await emitWheel(fake: fake, id: sensorID, revolutions: 100, eventTime: 1_024)
            await emitWheel(fake: fake, id: sensorID, revolutions: 10_126, eventTime: 2_048)
            await emitWheel(fake: fake, id: sensorID, revolutions: 10_127, eventTime: 3_072)
            let sample = await iterator.next()
            #expect(sample?.deltaDistance.converted(to: .meters).value == 2.105)
            #expect(sample?.deltaTime.converted(to: .seconds).value == 1.0)
        }
    }

    private func emitWheel(
        fake: FakeBluetoothCentral,
        id: UUID,
        revolutions: UInt32,
        eventTime: UInt16,
    ) async {
        await CSCClientTestSupport.emitMeasurement(
            CSCMeasurement(
                cumulativeWheelRevolutions: revolutions,
                lastWheelEventTime: eventTime,
            ),
            from: fake,
            peripheralID: id,
        )
    }
}

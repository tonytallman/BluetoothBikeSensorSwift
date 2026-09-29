import CSCClient
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct CrankRevolutionsTests {
    @Test func crankSamplesEmitAfterTwoNotifies() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let connected = try await CSCClientTestSupport.sensor(id: sensorID, central: fake).connect()
        let crank = try #require(connected.revolutions.crank)

        var sampleIterator = (await crank.crankSamples).makeAsyncIterator()
        var cadenceIterator = (await crank.cadence).makeAsyncIterator()

        await emitCrank(fake: fake, id: sensorID, revolutions: 10, eventTime: 1_024)
        await emitCrank(fake: fake, id: sensorID, revolutions: 11, eventTime: 2_048)

        let sample = await sampleIterator.next()
        let cadence = await cadenceIterator.next()
        #expect(sample?.deltaRevolutions == 1)
        #expect(sample?.deltaTime.converted(to: .seconds).value == 1.0)
        #expect(cadence?.value == 60.0)
        #expect(cadence?.unit == .revolutionsPerMinute)
        if let sample, let cadence {
            let timeSeconds = sample.deltaTime.converted(to: .seconds).value
            let implied = (Double(sample.deltaRevolutions) / timeSeconds) * 60.0
            #expect(abs(cadence.value - implied) < 0.001)
        }
    }

    @Test(arguments: [
        ("crankDeltaHappyPath", 1, 1.0, 60.0),
        ("zeroQuantityWithPositiveDeltaTimeEmitsCrank", 0, 1.0, 0.0),
        ("handlesCrankRevolutionWraparound", 1, 1.0, 60.0),
        ("crankEventTimeWrapPlausible", 1, Double(UInt16(1_024) &- UInt16(60_000)) / 1024.0, 9.366),
        ("crankWrapVersusImplausible", 2, 1.0, 120.0),
        ("crankNearBoundaryWrap", 4, 1.0, 240.0),
        ("crankCapExactlyThreeHundredRPMAccepted", 5, 1.0, 300.0),
    ] as [(String, UInt16, Double, Double)])
    func crankSampleMath(
        caseName: String,
        deltaRevolutions: UInt16,
        deltaSeconds: Double,
        expectedCadence: Double,
    ) {
        let sample = CrankRevolutions.sample(revolutions: deltaRevolutions, seconds: deltaSeconds)
        #expect(sample != nil)
        if let sample {
            let cadence = Double(sample.deltaRevolutions) / sample.deltaTime.converted(to: .seconds).value * 60.0
            #expect(abs(cadence - expectedCadence) < (caseName == "crankEventTimeWrapPlausible" ? 0.1 : 0.01))
        }
    }

    @Test(arguments: [
        "crankEventTimeWrapImplausibleRate",
        "crankImplausibleDeltaReseeds",
        "crankCapJustOverThreeHundredRejected",
    ])
    func implausibleCrankDeltaIsDroppedAndReseeds(caseName: String) async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let connected = try await CSCClientTestSupport.sensor(id: sensorID, central: fake).connect()
        let crank = try #require(connected.revolutions.crank)
        var iterator = (await crank.crankSamples).makeAsyncIterator()

        switch caseName {
        case "crankEventTimeWrapImplausibleRate":
            let seconds = Double(UInt16(100) &- UInt16(65_500)) / 1024.0
            #expect(CrankRevolutions.sample(revolutions: 1, seconds: seconds) == nil)
        case "crankImplausibleDeltaReseeds":
            await emitCrank(fake: fake, id: sensorID, revolutions: 10, eventTime: 1_024)
            await emitCrank(fake: fake, id: sensorID, revolutions: 1_000, eventTime: 2_048)
            await emitCrank(fake: fake, id: sensorID, revolutions: 1_001, eventTime: 3_072)
            #expect(await iterator.next()?.deltaRevolutions == 1)
        case "crankCapJustOverThreeHundredRejected":
            await emitCrank(fake: fake, id: sensorID, revolutions: 0, eventTime: 0)
            await emitCrank(fake: fake, id: sensorID, revolutions: 5, eventTime: 1_023)
            await emitCrank(fake: fake, id: sensorID, revolutions: 6, eventTime: 1_023 + 1_024)
            let sample = await iterator.next()
            #expect(sample?.deltaRevolutions == 1)
            #expect(sample?.deltaTime.converted(to: .seconds).value == 1.0)
        default:
            Issue.record("Unknown case")
        }
    }

    private func emitCrank(
        fake: FakeBluetoothCentral,
        id: UUID,
        revolutions: UInt16,
        eventTime: UInt16,
    ) async {
        await CSCClientTestSupport.emitMeasurement(
            CSCMeasurement(
                cumulativeCrankRevolutions: revolutions,
                lastCrankEventTime: eventTime,
            ),
            from: fake,
            peripheralID: id,
        )
    }
}

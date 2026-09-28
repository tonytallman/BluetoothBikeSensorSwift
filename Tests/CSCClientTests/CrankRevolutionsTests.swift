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

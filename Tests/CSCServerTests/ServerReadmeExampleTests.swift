import CSCServer
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ServerReadmeExampleTests {
    /// Mirrors README → CSCServer → "Build and start". Differences: `start(peripheral:)` with a fake,
    /// and a measurement subscription before the yields.
    @Test func readmeServerExampleBuildsAndNotifies() async throws {
        struct ResetWheelCount: CumulativeWheelRevolutionsDelegate {
            func setCumulativeWheelRevolutions(_ cumulativeRevolutions: UInt32) async throws {
                // Store the new cumulative wheel count in your model.
            }
        }

        let (revolutions, input) = AsyncStream.makeStream(of: WheelAndCrankRevolution.self)

        let server = Server
            .wheelAndCrankRevolutions(revolutions, setCumulativeWheelRevolutions: ResetWheelCount())
            .staticSensorLocation(.rearDropout)
            .build()

        let fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)
        await fake.subscribeMeasurement(server: server, centralID: UUID())

        input.yield(WheelAndCrankRevolution(
            wheel: WheelRevolution(cumulativeRevolutions: 1_234, lastEventTime: 2_048),
            crank: CrankRevolution(cumulativeRevolutions: 56, lastEventTime: 2_048),
        ))

        let expected = CSCMeasurement(
            cumulativeWheelRevolutions: 1_234,
            lastWheelEventTime: 2_048,
            cumulativeCrankRevolutions: 56,
            lastCrankEventTime: 2_048,
        ).encode()!

        await fake.waitUntilUpdateValueCount(
            1,
            characteristic: CSCS.measurementUUID,
            matching: { $0 == expected },
        )

        await server.stop()
    }
}

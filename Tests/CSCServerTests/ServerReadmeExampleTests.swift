import CSCServer
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ServerReadmeExampleTests {
    /// Mirrors README → CSCServer → "Build and start". Differences: `start(peripheral:)` with a fake,
    /// and a measurement subscription before the yields.
    @Test func readmeServerExampleBuildsAndNotifies() async throws {
        struct ResetWheelCount: SetCumulativeWheelRevolutions {
            func setCumulativeWheelRevolutions(_ cumulativeRevolutions: UInt32) async throws {
                // Store the new cumulative wheel count in your model.
            }
        }

        let (wheelRevolutions, wheelInput) = AsyncStream.makeStream(of: WheelRevolution.self)
        let (crankRevolutions, crankInput) = AsyncStream.makeStream(of: CrankRevolution.self)

        let server = Server
            .wheelRevolutions(wheelRevolutions, setCumulativeWheelRevolutions: ResetWheelCount())
            .crankRevolutions(crankRevolutions)
            .staticSensorLocation(.rearDropout)
            .build()

        let fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)
        await fake.subscribeMeasurement(server: server, centralID: UUID())

        wheelInput.yield(WheelRevolution(cumulativeRevolutions: 1_234, lastEventTime: 2_048))
        crankInput.yield(CrankRevolution(cumulativeRevolutions: 56, lastEventTime: 2_048))

        await fake.waitUntilRecordedCallsSatisfy { calls in
            let measurements = calls.compactMap { call -> CSCMeasurement? in
                if case let .updateValue(value, _, CSCS.measurementUUID, _) = call {
                    return CSCMeasurement.decode(value)
                }
                return nil
            }
            return measurements.contains { $0.cumulativeWheelRevolutions == 1_234 }
                && measurements.contains { $0.cumulativeCrankRevolutions == 56 }
        }

        await server.stop()
    }
}

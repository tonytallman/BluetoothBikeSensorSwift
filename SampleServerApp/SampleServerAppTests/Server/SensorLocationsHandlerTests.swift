import CSCServer
import Testing
@testable import SampleServerApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SensorLocationsHandlerTests {
    @Test func supportedAndCurrentMatchConstruction() {
        let handler = SensorLocationsHandler(
            supported: [.frontWheel, .rearDropout],
            current: .rearDropout,
            sink: nil,
        )
        #expect(handler.supported == [.frontWheel, .rearDropout])
        #expect(handler.current == .rearDropout)
    }

    @Test func updateRecordsLocation() async throws {
        let sink = FakeControlPointSink()
        let handler = SensorLocationsHandler(
            supported: [.rightCrank],
            current: .rightCrank,
            sink: sink,
        )
        try await handler.update(.rightCrank)
        #expect(sink.locations == [.rightCrank])
    }

    @Test func cancellationThrowsAndRecordsNothing() async {
        let sink = FakeControlPointSink()
        let handler = SensorLocationsHandler(
            supported: [.rightCrank],
            current: .rightCrank,
            sink: sink,
        )
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    try await handler.update(.rightCrank)
                } catch is CancellationError {
                } catch {
                    Issue.record("Unexpected error \(error)")
                }
            }
        }
        #expect(sink.locations.isEmpty)
    }
}

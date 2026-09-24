import CSCServer
import Testing
@testable import SampleServerApp

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct CumulativeWheelRevolutionsHandlerTests {
    @Test func recordsValueOnSink() async throws {
        let sink = FakeControlPointSink()
        let handler = CumulativeWheelRevolutionsHandler(sink: sink)
        try await handler.setCumulativeWheelRevolutions(1000)
        #expect(sink.cumulativeValues == [1000])
    }

    @Test func cancellationThrowsAndRecordsNothing() async {
        let sink = FakeControlPointSink()
        let handler = CumulativeWheelRevolutionsHandler(sink: sink)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    try await handler.setCumulativeWheelRevolutions(1)
                } catch is CancellationError {
                } catch {
                    Issue.record("Unexpected error \(error)")
                }
            }
        }
        #expect(sink.cumulativeValues.isEmpty)
    }

    @Test func nilSinkSucceedsSilently() async throws {
        let handler = CumulativeWheelRevolutionsHandler(sink: nil)
        try await handler.setCumulativeWheelRevolutions(5)
    }
}

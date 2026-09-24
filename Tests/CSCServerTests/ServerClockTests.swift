import CSCServer
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ServerClockTests {
    @Test func continuousClockHonorsCancellation() async throws {
        let clock = ContinuousServerClock()
        let sleeper = Task {
            try await clock.sleep(for: .seconds(60))
        }
        sleeper.cancel()
        await #expect(throws: CancellationError.self) {
            try await sleeper.value
        }

        try await clock.sleep(for: .zero)
    }
}

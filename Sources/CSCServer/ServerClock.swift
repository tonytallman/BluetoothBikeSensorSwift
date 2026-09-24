/// Time source for the control point procedure timeout. Tests inject a manual clock.
package protocol ServerClock: Sendable {
    /// Suspends for `duration`. Throws `CancellationError` when the calling task is cancelled.
    func sleep(for duration: Duration) async throws
}

/// ``ServerClock`` backed by `ContinuousClock`.
package struct ContinuousServerClock: ServerClock {
    package init() {}

    package func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

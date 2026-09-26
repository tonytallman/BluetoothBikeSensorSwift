import Foundation
package import CSCWire

/// CSC sensor server built from revolution sequences and optional location settings.
public final class Server: Sendable {
    package let configuration: ServerConfiguration

    private let runtime: ServerRuntime

    internal init(configuration: ServerConfiguration) {
        self.configuration = configuration
        runtime = ServerRuntime(configuration: configuration)
    }

    deinit {
        let runtime = runtime
        Task {
            await runtime.stop()
        }
    }

    /// Publishes the CSC service and advertises `0x1816`. Returns once advertising has started.
    ///
    /// Throws ``ServerError/alreadyStarted`` if this server is already starting, running, or stopping.
    /// Keep a strong reference while serving. Releasing a started server stops it in the background;
    /// `await` ``stop()`` before starting another server.
    ///
    /// If Bluetooth leaves the powered-on state while serving, the server stops advertising, drops all
    /// subscriptions and samples, and republishes the same service when Bluetooth is powered on again.
    /// If republishing fails, the server stays suspended until the next power cycle.
    public func start() async throws {
        try await runtime.start(peripheral: nil, clock: ContinuousServerClock())
    }

    /// Yields 0 while stopped or starting, and when Bluetooth loss suspends the server.
    ///
    /// New stream consumers receive the latest count immediately. The stream does not finish on
    /// `stop()`; cancel the consuming task when observation ends.
    public var measurementSubscriberCount: AsyncStream<Int> {
        get async {
            await runtime.measurementSubscriberCount()
        }
    }

    /// Stops advertising, removes the CSC service, and ends measurement notifications.
    ///
    /// Cancels an in-flight control point delegate call and waits for it to return.
    /// Returns only after teardown. Idempotent.
    public func stop() async {
        await runtime.stop()
    }

    /// Same-package tests inject ``FakeBluetoothPeripheral`` and a manual clock for the procedure timeout.
    package func start(
        peripheral: any BluetoothPeripheral,
        clock: any ServerClock = ContinuousServerClock(),
    ) async throws {
        try await runtime.start(peripheral: peripheral, clock: clock)
    }

    /// Blocks until the measurement subscriber set equals `ids`.
    package func waitForMeasurementSubscribers(_ ids: Set<UUID>) async {
        await runtime.waitForMeasurementSubscribers(ids)
    }

    /// Returns once a subscriber waiter is parked on the running session.
    package func waitUntilMeasurementSubscriberWaiterParked() async {
        await runtime.waitUntilMeasurementSubscriberWaiterParked()
    }

    /// Blocks until the control-point subscriber set equals `ids`.
    package func waitForControlPointSubscribers(_ ids: Set<UUID>) async {
        await runtime.waitForControlPointSubscribers(ids)
    }

    /// Blocks until no control-point procedure is in progress.
    package func waitUntilControlPointProcedureIdle() async {
        await runtime.waitUntilControlPointProcedureIdle()
    }

    /// Blocks until the accepted measurement count reaches `count`.
    package func waitUntilAcceptedMeasurementCount(_ count: Int) async {
        await runtime.waitUntilAcceptedMeasurementCount(count)
    }

    /// Blocks until the outbound queue holds at least `count` items.
    package func waitUntilOutboundCount(atLeast count: Int) async {
        await runtime.waitUntilOutboundCount(atLeast: count)
    }

    /// Returns once the outbound pump is parked waiting for a ready-to-update signal.
    package func waitUntilNotifyReadyWaiterParked() async {
        await runtime.waitUntilNotifyReadyWaiterParked()
    }

    /// Whether the running session lost Bluetooth and has not republished yet. Waits for a
    /// recovery that is already in progress to finish.
    package var isRadioSuspended: Bool {
        get async { await runtime.isRadioSuspended }
    }

    /// Blocks until `count` callers have entered ``ServerRuntime`` teardown waiting.
    package func waitUntilStopWaiterCount(_ count: Int) async {
        await runtime.waitUntilFinishStoppingEntryCount(count)
    }
}

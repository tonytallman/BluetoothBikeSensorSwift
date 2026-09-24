import Foundation
package import CSCWire

/// CSC sensor server configuration built from revolution sequences and optional location settings.
public final class Server: Sendable {
    package let feature: CSCFeature
    package let service: PeripheralService
    package let wheel: WheelConfiguration?
    package let crankRevolutions: AnyAsyncSequence<CrankRevolution>?
    /// Build-time location configuration. For `.multiple`, the byte on `0x2A5D` while serving is not this snapshot after a successful Update.
    package let location: ServerLocationConfiguration

    private let runtime: ServerRuntime

    internal init(
        feature: CSCFeature,
        service: PeripheralService,
        wheel: WheelConfiguration?,
        crankRevolutions: AnyAsyncSequence<CrankRevolution>?,
        location: ServerLocationConfiguration,
    ) {
        self.feature = feature
        self.service = service
        self.wheel = wheel
        self.crankRevolutions = crankRevolutions
        self.location = location
        runtime = ServerRuntime(
            service: service,
            wheel: wheel,
            crankRevolutions: crankRevolutions,
            location: location,
        )
    }

    deinit {
        let runtime = runtime
        Task {
            await runtime.stop()
        }
    }

    /// Publishes the CSC service and advertises `0x1816`. Returns once advertising has started.
    ///
    /// Only one `Server` per process can be started at a time; another `Server`'s `start()` throws
    /// ``ServerError/alreadyStarted`` until this one has stopped. Keep a strong reference while serving.
    /// Releasing a started server stops it in the background; `await` ``stop()`` if you need to start
    /// another server right away.
    ///
    /// If Bluetooth leaves the powered-on state while serving, the server stops advertising, drops all
    /// subscriptions and samples, and republishes the same service when Bluetooth is powered on again.
    /// If republishing fails, the server stays suspended until the next power cycle.
    public func start() async throws {
        try await runtime.start(peripheral: nil, clock: ContinuousServerClock(), liveServers: .shared)
    }

    /// Stops advertising, removes the CSC service, and ends measurement notifications.
    ///
    /// Cancels an in-flight control point delegate call and waits for it to return.
    /// Returns only after teardown, when another `Server` can start. Idempotent.
    public func stop() async {
        await runtime.stop()
    }

    /// Same-package tests inject ``FakeBluetoothPeripheral``, a manual clock for the procedure timeout,
    /// and a live-server registry. The default registry is fresh, so tests do not share the process slot.
    package func start(
        peripheral: any BluetoothPeripheral,
        clock: any ServerClock = ContinuousServerClock(),
        liveServers: LiveServerRegistry = LiveServerRegistry(),
    ) async throws {
        try await runtime.start(peripheral: peripheral, clock: clock, liveServers: liveServers)
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
}

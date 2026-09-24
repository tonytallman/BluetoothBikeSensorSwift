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

    /// Publishes the CSC service and advertises `0x1816`. Returns once advertising has started.
    public func start() async throws {
        try await runtime.start(peripheral: nil)
    }

    /// Stops advertising, removes the CSC service, and ends measurement notifications.
    ///
    /// Returns only after teardown. Idempotent.
    public func stop() async {
        await runtime.stop()
    }

    /// Same-package tests inject ``FakeBluetoothPeripheral``.
    package func start(peripheral: any BluetoothPeripheral) async throws {
        try await runtime.start(peripheral: peripheral)
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
}

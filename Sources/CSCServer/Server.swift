import Foundation
package import CSCWire

/// CSC sensor server configuration built from revolution sequences and optional location settings.
public final class Server: Sendable {
    package let feature: CSCFeature
    package let service: PeripheralService
    package let wheel: WheelConfiguration?
    package let crankRevolutions: AnyAsyncSequence<CrankRevolution>?
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
        runtime = ServerRuntime(service: service, crankRevolutions: crankRevolutions)
    }

    /// Publishes the CSC service and advertises `0x1816` until ``stop()`` or cancellation.
    ///
    /// Returns when the session has stopped. Cancellation throws `CancellationError` after teardown.
    public func start() async throws {
        try await runtime.start(peripheral: nil, poweredOnTimeoutNanoseconds: 2_000_000_000)
    }

    /// Stops advertising, removes the CSC service, and ends measurement notifications.
    ///
    /// Returns only after teardown. Idempotent.
    public func stop() async {
        await runtime.stop()
    }

    /// Same-package tests inject ``FakeBluetoothPeripheral``.
    ///
    /// `poweredOnTimeoutNanoseconds` defaults to `2_000_000_000` and stays off the public API.
    package func start(
        peripheral: any BluetoothPeripheral,
        poweredOnTimeoutNanoseconds: UInt64 = 2_000_000_000,
    ) async throws {
        try await runtime.start(
            peripheral: peripheral,
            poweredOnTimeoutNanoseconds: poweredOnTimeoutNanoseconds,
        )
    }

    /// Multicast stream of measurement subscriber central IDs. Does not replay prior yields.
    package func measurementSubscriberUpdates() async -> AsyncStream<Set<UUID>> {
        await runtime.measurementSubscriberUpdates()
    }
}

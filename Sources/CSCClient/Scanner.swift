internal import CSCWire
import Foundation

/// Deadlines injected into ``Scanner``, ``DiscoveredSensor/connect()``, and ``ControlPoint``.
///
/// Production ``Scanner/init()`` uses the defaults: 2 seconds for Bluetooth to leave `.unknown`
/// or `.resetting` before a scan finishes empty, 10 seconds for the link to come up, and 30
/// seconds for one SC Control Point procedure. Tests pass shorter values. Not part of the
/// public API.
package struct Timeouts: Sendable {
    package let bluetoothPowerOn: Duration
    package let connect: Duration
    package let controlPointProcedure: Duration

    package init(
        bluetoothPowerOn: Duration = .seconds(2),
        connect: Duration = .seconds(10),
        controlPointProcedure: Duration = .seconds(30),
    ) {
        self.bluetoothPowerOn = bluetoothPowerOn
        self.connect = connect
        self.controlPointProcedure = controlPointProcedure
    }
}

/// Entry point for discovering CSCS (Cycling Speed and Cadence Service) sensors.
///
/// Create a `Scanner`, call ``scan()`` to receive ``DiscoveredSensor`` values, then
/// connect to read live measurements. The library is not MainActor-bound; update UI on
/// the main actor in your app.
public struct Scanner: Sendable {
    private let central: any BluetoothCentral
    private let timeouts: Timeouts

    /// Client entry point. Creates the production central.
    ///
    /// On iOS, creating that central is what can raise the Bluetooth permission prompt. The
    /// prompt often outlasts the scan power wait; if ``scan()`` finishes empty, call it again
    /// after the user answers.
    #if canImport(CoreBluetooth)
    public init() {
        self.init(central: CoreBluetoothCentral())
    }
    #endif

    /// Test and same-package injection. `timeouts` defaults to the production deadlines.
    package init(central: any BluetoothCentral, timeouts: Timeouts = Timeouts()) {
        self.central = central
        self.timeouts = timeouts
    }

    /// Scans for peripherals advertising CSCS (`0x1816`).
    ///
    /// Each call is its own scan session. Cancel the returned stream, or the task iterating it,
    /// to stop that session. Stopping an older session does not stop a newer one, and a start
    /// that loses the race with its own stop never turns the radio on.
    ///
    /// Discoveries are subscribed before the radio scan starts. The discovery stream does not
    /// replay, so subscribing afterward would drop the first advertisements. Each peripheral id
    /// is yielded at most once per session; a later ``scan()`` can yield it again. An
    /// advertisement that omits service UUIDs is still yielded. One that lists services and does
    /// not include CSCS is not.
    ///
    /// `.unsupported`, `.unauthorized`, and `.poweredOff` finish the stream immediately. `.unknown`
    /// and `.resetting` are waited out for 2 seconds. Turning Bluetooth off while a scan is
    /// already running does not finish the stream; cancel it to stop.
    public func scan() -> AsyncStream<DiscoveredSensor> {
        let central = central

        return AsyncStream { continuation in
            let session = ScanSessionID.issue()
            let scanTask = Task {
                guard await Self.waitForPoweredOn(central: central, timeouts: timeouts) else {
                    continuation.finish()
                    return
                }

                // Cancellation during the power wait or the discoveries subscribe must not start
                // the radio. `onTermination` has already asked this session to stop.
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }

                let discoveries = await central.discoveries
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }

                await central.startScanning(serviceUUIDs: [CSCS.serviceUUID], session: session)

                var seenIDs: Set<UUID> = []

                for await event in discoveries where Self.matchesCSCScan(peripheral: event) {
                    let sensor = DiscoveredSensor(event, central: central, timeouts: timeouts)
                    guard seenIDs.insert(sensor.id).inserted else { continue }
                    continuation.yield(sensor)
                }
            }

            // `onTermination` cannot await. The session id makes this late `stopScanning` a no-op
            // when a newer scan on the same central is already the active one.
            continuation.onTermination = { _ in
                scanTask.cancel()
                Task {
                    await central.stopScanning(session: session)
                }
            }
        }
    }

    /// The radio is already filtered to CSCS. This drops an advertisement that lists service
    /// UUIDs and does not include CSCS. An empty list is kept: some stacks, including iOS
    /// background delivery, omit service UUIDs even for a service-filtered scan.
    private static func matchesCSCScan(peripheral: DiscoveredPeripheral) -> Bool {
        peripheral.serviceUUIDs.isEmpty || peripheral.serviceUUIDs.contains(CSCS.serviceUUID)
    }

    /// `true` when the central is `.poweredOn` in time to scan.
    ///
    /// `.poweredOn` returns immediately. `.unsupported`, `.unauthorized`, and `.poweredOff`
    /// return `false` immediately; a denied permission prompt stays `.unauthorized` and is not
    /// waited out. `.unknown` and `.resetting` race ``BluetoothCentral/stateUpdates`` against
    /// ``Timeouts/bluetoothPowerOn``. The sleep side rechecks ``BluetoothCentral/currentState``
    /// so a transition that lands in the same moment as the deadline still counts.
    ///
    /// ``BluetoothCentral/stateSubscriptionSnapshot()`` is what makes the wait safe. The
    /// subscription and the state read commit together, so a transition is either already
    /// reflected in the returned state or still queued on the new stream.
    private static func waitForPoweredOn(central: any BluetoothCentral, timeouts: Timeouts) async -> Bool {
        let unavailableStates: Set<BluetoothState> = [.unsupported, .unauthorized, .poweredOff]

        let (stateUpdates, initialState) = await central.stateSubscriptionSnapshot()
        if initialState == .poweredOn {
            return true
        }
        if unavailableStates.contains(initialState) {
            return false
        }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await state in stateUpdates {
                    if state == .poweredOn {
                        return true
                    }
                    if unavailableStates.contains(state) {
                        return false
                    }
                }
                return false
            }

            group.addTask {
                try? await Task.sleep(for: timeouts.bluetoothPowerOn)
                return await central.currentState == .poweredOn
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

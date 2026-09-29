internal import CSCWire
import Foundation

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

    /// Client entry point. Production dependencies are wired here.
    #if canImport(CoreBluetooth)
    public init() {
        self.init(central: CoreBluetoothCentral())
    }
    #endif

    /// Test and same-package injection only.
    package init(central: any BluetoothCentral, timeouts: Timeouts = Timeouts()) {
        self.central = central
        self.timeouts = timeouts
    }

    /// Scans for CSCS-capable sensors filtered to service UUID `0x1816`.
    ///
    /// Yields each peripheral at most once per scan session. Cancel the returned stream
    /// to stop scanning. If Bluetooth is unavailable when scanning starts, the stream
    /// finishes without yielding.
    public func scan() -> AsyncStream<DiscoveredSensor> {
        let central = central

        return AsyncStream { continuation in
            let session = ScanSessionID.issue()
            let scanTask = Task {
                guard await Self.waitForPoweredOn(central: central, timeouts: timeouts) else {
                    continuation.finish()
                    return
                }

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

            continuation.onTermination = { _ in
                scanTask.cancel()
                Task {
                    await central.stopScanning(session: session)
                }
            }
        }
    }

    private static func matchesCSCScan(peripheral: DiscoveredPeripheral) -> Bool {
        peripheral.serviceUUIDs.isEmpty || peripheral.serviceUUIDs.contains(CSCS.serviceUUID)
    }

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

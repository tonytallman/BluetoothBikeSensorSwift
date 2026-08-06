import Foundation

/// Entry point for discovering CSCS (Cycling Speed and Cadence Service) sensors.
///
/// Create a `Scanner`, call ``scan()`` to receive ``DiscoveredSensor`` values, then
/// connect to read live measurements. The library is not MainActor-bound; update UI on
/// the main actor in your app.
public struct Scanner: Sendable {
    private static let poweredOnTimeoutNanoseconds: UInt64 = 2_000_000_000

    private let central: any BluetoothCentral

    /// Client entry point. Production dependencies are wired here.
    public init() {
        self.init(central: CoreBluetoothCentral())
    }

    /// Test and same-package injection only.
    package init(central: any BluetoothCentral) {
        self.central = central
    }

    /// Scans for CSCS-capable sensors filtered to service UUID `0x1816`.
    ///
    /// Yields each peripheral at most once per scan session. Cancel the returned stream
    /// to stop scanning. If Bluetooth is unavailable when scanning starts, the stream
    /// finishes without yielding.
    public func scan() -> AsyncStream<DiscoveredSensor> {
        let central = central

        return AsyncStream { continuation in
            let scanTask = Task {
                guard await Self.waitForPoweredOn(central: central) else {
                    continuation.finish()
                    return
                }

                let discoveries = await central.discoveries
                await central.startScanning(serviceUUIDs: [CSCS.serviceUUID])

                var seenIDs: Set<UUID> = []

                for await event in discoveries {
                    guard !Task.isCancelled else { break }
                    guard let sensor = DiscoveredSensorMapper.map(event, central: central) else { continue }
                    guard seenIDs.insert(sensor.id).inserted else { continue }
                    continuation.yield(sensor)
                }

                await central.stopScanning()
                continuation.finish()
            }

            continuation.onTermination = { _ in
                scanTask.cancel()
                Task {
                    await central.stopScanning()
                }
            }
        }
    }

    private static func waitForPoweredOn(central: any BluetoothCentral) async -> Bool {
        let unavailableStates: Set<BluetoothState> = [.unsupported, .unauthorized, .poweredOff]

        let initialState = await central.currentState
        if initialState == .poweredOn {
            return true
        }
        if unavailableStates.contains(initialState) {
            return false
        }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                let stateUpdates = await central.stateUpdates
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
                try? await Task.sleep(nanoseconds: poweredOnTimeoutNanoseconds)
                return await central.currentState == .poweredOn
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

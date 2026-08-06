import Foundation

/// A CSCS sensor discovered during an active scan.
///
/// Obtain instances only from ``Scanner/scan()``. Capability flags on this type are
/// best-effort from discovery; after ``connect()``, rely on optional ``ConnectedSensor/speed``
/// and ``ConnectedSensor/cadence`` streams for supported metrics.
public struct DiscoveredSensor: Sendable {
    nonisolated(unsafe) package static var connectTimeoutNanoseconds: UInt64 = 10_000_000_000

    /// Stable identifier for the peripheral.
    public let id: UUID
    /// Advertised or peripheral name, when available.
    public let name: String?
    /// Manufacturer resolved from advertisement data, when available.
    public let manufacturer: String?
    /// Best-effort speed support hint from discovery; refined on connect.
    public let hasSpeed: Bool
    /// Best-effort cadence support hint from discovery; refined on connect.
    public let hasCadence: Bool

    private let central: any BluetoothCentral

    package init(
        id: UUID,
        name: String?,
        manufacturer: String?,
        hasSpeed: Bool,
        hasCadence: Bool,
        central: any BluetoothCentral,
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.hasSpeed = hasSpeed
        self.hasCadence = hasCadence
        self.central = central
    }

    /// Connects to the sensor, discovers CSC characteristics, and enables notifications.
    ///
    /// - Returns: A ``ConnectedSensor`` for reading live measurements.
    /// - Throws: ``ConnectError`` when connection, discovery, or notification setup fails.
    public func connect() async throws -> ConnectedSensor {
        guard await central.currentState == .poweredOn else {
            throw ConnectError.notPoweredOn
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await central.connect(id: id)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: Self.connectTimeoutNanoseconds)
                    throw ConnectError.timeout
                }

                try await group.next()
                group.cancelAll()
            }
        } catch let error as ConnectError {
            throw error
        } catch let error as BluetoothCentralError {
            throw BluetoothCentralErrorMapping.connectError(from: error)
        } catch {
            throw ConnectError.failed(reason: error.localizedDescription)
        }

        do {
            try await central.discoverServices(id: id, serviceUUIDs: [CSCS.serviceUUID])
        } catch {
            try? await central.disconnect(id: id)
            if let centralError = error as? BluetoothCentralError {
                throw BluetoothCentralErrorMapping.connectError(from: centralError)
            }
            throw ConnectError.serviceDiscoveryFailed(reason: error.localizedDescription)
        }

        let refinedCapabilities: (hasSpeed: Bool, hasCadence: Bool)
        do {
            refinedCapabilities = try await CSCConnectionSetup.prepare(
                central: central,
                id: id,
                fallbackHasSpeed: hasSpeed,
                fallbackHasCadence: hasCadence,
            )
        } catch {
            try? await central.disconnect(id: id)
            if let centralError = error as? BluetoothCentralError {
                throw BluetoothCentralErrorMapping.connectError(from: centralError)
            }
            throw ConnectError.serviceDiscoveryFailed(reason: error.localizedDescription)
        }

        return ConnectedSensor(
            id: id,
            name: name,
            manufacturer: manufacturer,
            hasSpeed: refinedCapabilities.hasSpeed,
            hasCadence: refinedCapabilities.hasCadence,
            central: central,
        )
    }
}

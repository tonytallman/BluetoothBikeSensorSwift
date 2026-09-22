internal import CSCWire
import Foundation

/// A CSCS sensor discovered during an active scan.
///
/// Obtain instances only from ``Scanner/scan()``. Capability flags on this type are
/// best-effort from discovery; after ``connect()``, rely on ``ConnectedSensor/revolutions``
/// and ``ConnectedSensor/location`` for supported features.
public struct DiscoveredSensor: Sendable {
    nonisolated(unsafe) package static var connectTimeoutNanoseconds: UInt64 = 10_000_000_000

    /// Stable identifier for the peripheral.
    public let id: UUID
    /// Advertised or peripheral name, when available.
    public let name: String?
    /// Manufacturer resolved from advertisement data, when available.
    public let manufacturer: String?
    /// Best-effort speed support hint from discovery.
    public let hasSpeed: Bool
    /// Best-effort cadence support hint from discovery.
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

        let connectionResult: CSCConnectionResult
        do {
            connectionResult = try await CSCConnectionSetup.prepare(
                central: central,
                id: id,
            )
        } catch let error as ConnectError {
            try? await central.disconnect(id: id)
            throw error
        } catch {
            try? await central.disconnect(id: id)
            if let centralError = error as? BluetoothCentralError {
                throw BluetoothCentralErrorMapping.connectError(from: centralError)
            }
            throw ConnectError.serviceDiscoveryFailed(reason: error.localizedDescription)
        }

        return await Self.makeConnectedSensor(
            id: id,
            name: name,
            manufacturer: manufacturer,
            connectionResult: connectionResult,
            central: central,
        )
    }

    private static func makeConnectedSensor(
        id: UUID,
        name: String?,
        manufacturer: String?,
        connectionResult: CSCConnectionResult,
        central: any BluetoothCentral,
    ) async -> ConnectedSensor {
        let stateBox = MeasurementStateBox()
        let controlPointSession = CSCControlPointSession(
            central: central,
            peripheralID: id,
            controlPointAvailable: connectionResult.controlPointAvailable,
        )

        if connectionResult.controlPointAvailable {
            await controlPointSession.startListener()
        }

        let revolutions = Self.makeRevolutions(
            resolved: connectionResult.revolutions,
            stateBox: stateBox,
            controlPointSession: controlPointSession,
        )

        let location: LocationSupport
        switch connectionResult.location {
        case .unavailable:
            location = .unavailable
        case let .fixed(sensorLocation):
            location = .fixed(sensorLocation)
        case let .multiple(supported, current):
            location = .multiple(
                MultipleSensorLocations(
                    supported: supported,
                    current: current,
                    controlPointSession: controlPointSession,
                ),
            )
        }

        return ConnectedSensor(
            id: id,
            name: name,
            manufacturer: manufacturer,
            revolutions: revolutions,
            location: location,
            central: central,
            controlPointSession: controlPointSession,
            controlPointIndicationsEnabled: connectionResult.controlPointAvailable,
            stateBox: stateBox,
        )
    }

    private static func makeRevolutions(
        resolved: ResolvedRevolutions,
        stateBox: MeasurementStateBox,
        controlPointSession: CSCControlPointSession,
    ) -> RevolutionData {
        switch resolved {
        case .wheel:
            return .wheel(
                WheelRevolutions(
                    stateBox: stateBox,
                    controlPointSession: controlPointSession,
                ),
            )
        case .crank:
            return .crank(CrankRevolutions())
        case .wheelAndCrank:
            return .wheelAndCrank(
                WheelRevolutions(
                    stateBox: stateBox,
                    controlPointSession: controlPointSession,
                ),
                CrankRevolutions(),
            )
        }
    }
}

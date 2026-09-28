internal import CSCWire
import Foundation

/// A CSCS sensor discovered during an active scan.
///
/// Obtain instances only from ``Scanner/scan()``. After ``connect()``, rely on
/// ``ConnectedSensor/revolutions`` and ``ConnectedSensor/location`` for supported features.
public struct DiscoveredSensor: Sendable {
    /// Stable identifier for the peripheral.
    public let id: UUID
    /// Advertised or peripheral name, when available.
    public let name: String?
    /// Manufacturer resolved from advertisement data, when available.
    public let manufacturer: String?

    private let central: any BluetoothCentral
    private let timeouts: Timeouts

    package init(
        id: UUID,
        name: String?,
        manufacturer: String?,
        central: any BluetoothCentral,
        timeouts: Timeouts = Timeouts(),
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.central = central
        self.timeouts = timeouts
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
                    try await Task.sleep(for: timeouts.connect)
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
                controlPointProcedure: timeouts.controlPointProcedure,
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
            timeouts: timeouts,
        )
    }

    private static func makeConnectedSensor(
        id: UUID,
        name: String?,
        manufacturer: String?,
        connectionResult: CSCConnectionResult,
        central: any BluetoothCentral,
        timeouts: Timeouts,
    ) async -> ConnectedSensor {
        let stateBox = MeasurementStateBox()
        let controlPoint = connectionResult.controlPoint

        let revolutions = Self.makeRevolutions(
            resolved: connectionResult.revolutions,
            stateBox: stateBox,
            controlPoint: controlPoint,
        )

        let location: LocationSupport
        switch connectionResult.location {
        case .unavailable:
            location = .unavailable
        case let .fixed(sensorLocation):
            location = .fixed(sensorLocation)
        case let .multiple(supported, current):
            guard let controlPoint else {
                fatalError("Multiple locations require control point")
            }
            location = .multiple(
                MultipleSensorLocations(
                    supported: supported,
                    current: current,
                    controlPoint: controlPoint,
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
            controlPoint: controlPoint,
            controlPointIndicationsEnabled: connectionResult.controlPointAvailable,
            stateBox: stateBox,
            timeouts: timeouts,
            centralEvents: connectionResult.centralEvents,
        )
    }

    private static func makeRevolutions(
        resolved: ResolvedRevolutions,
        stateBox: MeasurementStateBox,
        controlPoint: ControlPoint?,
    ) -> RevolutionData {
        switch resolved {
        case .wheel:
            return .wheel(
                WheelRevolutions(
                    stateBox: stateBox,
                    controlPoint: controlPoint,
                ),
            )
        case .crank:
            return .crank(CrankRevolutions())
        case .wheelAndCrank:
            return .wheelAndCrank(
                WheelRevolutions(
                    stateBox: stateBox,
                    controlPoint: controlPoint,
                ),
                CrankRevolutions(),
            )
        }
    }
}

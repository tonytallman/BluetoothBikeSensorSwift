internal import CSCWire
import Foundation

/// Errors thrown by ``DiscoveredSensor/connect()``.
public enum ConnectError: Error, Sendable, Equatable {
    /// Bluetooth is not powered on.
    case notPoweredOn
    /// Connection did not complete within the timeout.
    case timeout
    /// Connection failed for another reason.
    case failed(reason: String)
    /// The peripheral could not be found.
    case peripheralNotFound
    /// CSC service or characteristic discovery failed.
    case serviceDiscoveryFailed(reason: String)
}

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

    let central: any BluetoothCentral
    let timeouts: Timeouts

    init(
        _ peripheral: DiscoveredPeripheral,
        central: any BluetoothCentral,
        timeouts: Timeouts = Timeouts(),
    ) {
        id = peripheral.id
        name = peripheral.name
        manufacturer = Self.manufacturerName(from: peripheral.manufacturerData)
        self.central = central
        self.timeouts = timeouts
    }

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
            throw Self.connectError(from: error)
        } catch {
            throw ConnectError.failed(reason: error.localizedDescription)
        }

        do {
            return try await ConnectedSensor(connecting: self)
        } catch {
            try? await central.disconnect(id: id)
            throw Self.mapSetupError(error)
        }
    }

    private static func mapSetupError(_ error: Error) -> ConnectError {
        if let error = error as? ConnectError {
            return error
        }
        if let error = error as? ControlPointError {
            return .serviceDiscoveryFailed(reason: String(describing: error))
        }
        if let error = error as? BluetoothCentralError {
            return connectError(from: error)
        }
        return .serviceDiscoveryFailed(reason: error.localizedDescription)
    }

    private static func connectError(from error: BluetoothCentralError) -> ConnectError {
        switch error {
        case .notPoweredOn:
            return .notPoweredOn
        case .peripheralNotFound:
            return .peripheralNotFound
        case let .connectionFailed(_, reason):
            return .failed(reason: reason)
        case let .disconnected(_, reason):
            return .failed(reason: reason ?? "Disconnected during connect")
        case let .serviceNotFound(_, serviceUUID):
            return .serviceDiscoveryFailed(reason: "Service not found: \(serviceUUID)")
        case let .characteristicNotFound(_, serviceUUID, characteristicUUID):
            return .serviceDiscoveryFailed(
                reason: "Characteristic not found: \(characteristicUUID) on \(serviceUUID)",
            )
        case let .attApplicationError(code):
            return .serviceDiscoveryFailed(reason: "ATT error \(code)")
        }
    }

    /// Bluetooth SIG company identifiers (16-bit), little-endian in advertisement data.
    private static let companyNames: [UInt16: String] = [
        0x006D: "Garmin",
        0x0077: "Wahoo Fitness",
        0x0099: "Stages Cycling",
        0x00D1: "Quarq",
        0x0137: "Magene",
        0x0154: "Cycling Power Meter",
        0x0157: "SRAM",
    ]

    private static func manufacturerName(from manufacturerData: Data?) -> String? {
        guard let manufacturerData, manufacturerData.count >= 2 else {
            return nil
        }

        let bytes = Array(manufacturerData.prefix(2))
        let companyID = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        return companyNames[companyID]
    }
}

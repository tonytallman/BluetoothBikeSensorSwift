internal import CSCWire
import Foundation

/// Errors thrown by ``DiscoveredSensor/connect()``.
public enum ConnectError: Error, Sendable, Equatable {
    case notPoweredOn
    case timeout
    case failed(reason: String)
    case peripheralNotFound
    case serviceDiscoveryFailed(reason: String)
}

/// A CSCS sensor discovered during an active scan.
public struct DiscoveredSensor: Sendable {
    public let id: UUID
    public let name: String?
    public let manufacturer: String?

    package let central: any BluetoothCentral
    package let timeouts: Timeouts

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
        } catch let error as ConnectError {
            try? await central.disconnect(id: id)
            throw error
        } catch let error as ControlPointError {
            try? await central.disconnect(id: id)
            throw ConnectError.serviceDiscoveryFailed(reason: String(describing: error))
        } catch let error as BluetoothCentralError {
            try? await central.disconnect(id: id)
            throw Self.connectError(from: error)
        } catch {
            try? await central.disconnect(id: id)
            throw ConnectError.serviceDiscoveryFailed(reason: error.localizedDescription)
        }
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

internal import CSCWire
import Foundation

/// Errors thrown by ``DiscoveredSensor/connect()``.
public enum ConnectError: Error, Sendable, Equatable {
    /// Bluetooth was not `.poweredOn` when connect was attempted. Connect does not wait for power.
    case notPoweredOn
    /// The link did not come up within `timeouts.connect` (10 seconds by default). The in-flight
    /// connect is cancelled.
    case timeout
    /// The link failed, or connect was cancelled, for a reason other than the cases above.
    ///
    /// `reason` is diagnostic text (the underlying error's description, or a short literal).
    /// It is not user-facing copy.
    case failed(reason: String)
    /// The peripheral could not be found.
    case peripheralNotFound
    /// CSC service, characteristic, or connect-time control-point setup failed.
    ///
    /// `reason` is diagnostic text, not user-facing copy. Request Supported Sensor Locations
    /// runs during connect for a multiple-location sensor; a failure there is this case, not
    /// a ``ControlPointError`` for the caller.
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

    /// Same-package construction when there is no discovery event, so tests can connect a
    /// chosen id through an injected central.
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

    /// Connects, discovers CSC characteristics, and returns a sensor that is already notifying.
    ///
    /// Races the link against `timeouts.connect` (10 seconds by default). Whichever finishes first
    /// wins and the other task is cancelled. A timeout cancels the in-flight connect so the radio
    /// does not stay connecting, and throws ``ConnectError/timeout``. A cancelled caller surfaces as
    /// ``ConnectError/failed(reason:)``.
    ///
    /// Does not wait for Bluetooth power. Anything other than `.poweredOn` throws
    /// ``ConnectError/notPoweredOn`` before a connect is attempted.
    ///
    /// If the link comes up and later GATT setup throws, the peripheral is disconnected before
    /// that error propagates, so a failed connect does not leave the link open.
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
            throw BluetoothCentralConnectErrorMapping.connectError(from: error)
        } catch {
            throw ConnectError.failed(reason: "\(error)")
        }

        do {
            return try await ConnectedSensor(connecting: self)
        } catch {
            try? await central.disconnect(id: id)
            throw Self.mapSetupError(error)
        }
    }

    /// Fallback for setup failures that escape ``ConnectedSensor``'s initializer.
    ///
    /// Request Supported Sensor Locations already maps ``ControlPointError`` to
    /// ``ConnectError/serviceDiscoveryFailed`` before it leaves the initializer. A
    /// ``ControlPointError`` that still arrives here takes the same case.
    /// ``BluetoothCentralError`` goes through ``BluetoothCentralConnectErrorMapping``. Any other
    /// error uses `"\(error)"`.
    private static func mapSetupError(_ error: Error) -> ConnectError {
        if let error = error as? ConnectError {
            return error
        }
        if let error = error as? ControlPointError {
            return .serviceDiscoveryFailed(reason: String(describing: error))
        }
        if let error = error as? BluetoothCentralError {
            return BluetoothCentralConnectErrorMapping.connectError(from: error)
        }
        return .serviceDiscoveryFailed(reason: "\(error)")
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

    /// The first two bytes of Manufacturer Specific Data are the Bluetooth SIG company id,
    /// little-endian. Only ids in ``companyNames`` become a string. A short buffer or an
    /// unlisted id is `nil`, not a formatted unknown name.
    private static func manufacturerName(from manufacturerData: Data?) -> String? {
        guard let manufacturerData, manufacturerData.count >= 2 else {
            return nil
        }

        let bytes = Array(manufacturerData.prefix(2))
        let companyID = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        return companyNames[companyID]
    }
}

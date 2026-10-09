import Foundation

/// Maps ``BluetoothCentralError`` into ``ConnectError`` for ``DiscoveredSensor/connect()``
/// and for the feature read inside ``ConnectedSensor``.
///
/// A drop during connect is ``ConnectError/failed(reason:)``, not a disconnect error.
/// A nil disconnect reason becomes `"Disconnected during connect"`. Missing service,
/// missing characteristic, and ATT errors are ``ConnectError/serviceDiscoveryFailed``
/// because they happen while CSCS is being set up. ``ConnectError/timeout`` is not produced
/// here; the connect deadline throws that case directly.
package enum BluetoothCentralConnectErrorMapping {
    package static func connectError(from error: BluetoothCentralError) -> ConnectError {
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
}

import Foundation

enum BluetoothCentralErrorMapping {
    static func connectError(from error: BluetoothCentralError) -> ConnectError {
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
        }
    }

    static func disconnectError(from error: BluetoothCentralError) -> DisconnectError {
        switch error {
        case .peripheralNotFound:
            return .alreadyDisconnected
        case let .disconnected(_, reason):
            return .failed(reason: reason ?? "Disconnected")
        case let .connectionFailed(_, reason):
            return .failed(reason: reason)
        case .notPoweredOn:
            return .failed(reason: "Bluetooth is not powered on")
        case let .serviceNotFound(_, serviceUUID):
            return .failed(reason: "Service not found: \(serviceUUID)")
        case let .characteristicNotFound(_, serviceUUID, characteristicUUID):
            return .failed(reason: "Characteristic not found: \(characteristicUUID) on \(serviceUUID)")
        }
    }
}

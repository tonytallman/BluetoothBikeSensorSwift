import Foundation

/// Mirrors `CBManagerState` without depending on CoreBluetooth. `.unknown` and `.resetting` are
/// transient; startup waits through them (e.g. while the permission prompt is pending) rather
/// than failing immediately.
package enum BluetoothState: Sendable, Equatable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

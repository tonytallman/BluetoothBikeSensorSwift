import Foundation

/// Errors surfaced by ``Server/start()`` and ``Server/stop()``.
public enum ServerError: Error, Sendable, Equatable {
    /// The built configuration includes a control point, omits crank data, or is otherwise unsupported for ``Server/start()``.
    case unsupportedConfiguration
    /// ``Server/start()`` was called while a session is already active.
    case alreadyStarted
    /// Bluetooth is unavailable or not powered on during startup.
    case bluetoothUnavailable
    /// Publishing a GATT service or measurement notification failed.
    case publishFailed(reason: String)
    /// Starting advertising failed.
    case advertisingFailed(reason: String)
    /// The crank revolution sequence failed.
    case revolutionSequenceFailed(reason: String)
}

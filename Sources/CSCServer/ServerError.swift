import Foundation

/// Errors surfaced by ``Server/start()`` and ``Server/stop()``.
public enum ServerError: Error, Sendable, Equatable {
    /// Reserved for unsupported builder configurations. No current configuration throws this case.
    case unsupportedConfiguration
    /// ``Server/start()`` was called while a session is already active.
    case alreadyStarted
    /// Bluetooth is unavailable or not powered on during startup.
    case notPoweredOn
    /// Publishing a GATT service or measurement notification failed.
    case publishFailed(reason: String)
    /// Starting advertising failed.
    case advertisingFailed(reason: String)
}

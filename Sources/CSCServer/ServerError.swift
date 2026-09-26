import Foundation

/// Errors surfaced by ``Server/start()`` and ``Server/stop()``.
public enum ServerError: Error, Sendable, Equatable {
    /// Reserved for unsupported builder configurations. No current configuration throws this case.
    case unsupportedConfiguration
    /// This ``Server`` is already starting, running, or stopping.
    case alreadyStarted
    /// Bluetooth was unavailable, powered off, unauthorized, or unsupported during startup, or was lost before
    /// ``Server/start()`` finished.
    case notPoweredOn
    /// Publishing a GATT service or measurement notification failed.
    case publishFailed(reason: String)
    /// Starting advertising failed.
    case advertisingFailed(reason: String)
}

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

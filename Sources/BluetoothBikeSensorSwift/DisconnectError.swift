/// Errors thrown by ``ConnectedSensor/disconnect()``.
public enum DisconnectError: Error, Sendable, Equatable {
    /// Disconnect failed for a reason other than already being disconnected.
    case failed(reason: String)
    /// The sensor was already disconnected.
    case alreadyDisconnected
}

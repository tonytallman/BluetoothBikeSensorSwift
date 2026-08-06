public enum DisconnectError: Error, Sendable, Equatable {
    case failed(reason: String)
    case alreadyDisconnected
}

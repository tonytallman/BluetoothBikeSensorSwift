public enum ConnectError: Error, Sendable, Equatable {
    case notPoweredOn
    case timeout
    case failed(reason: String)
    case peripheralNotFound
    case serviceDiscoveryFailed(reason: String)
}

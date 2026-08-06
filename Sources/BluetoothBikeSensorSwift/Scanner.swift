public struct Scanner: Sendable {
    public init() {}

    public func scan() -> AsyncStream<DiscoveredSensor> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

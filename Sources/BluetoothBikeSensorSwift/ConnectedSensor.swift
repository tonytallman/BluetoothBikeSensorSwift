public final class ConnectedSensor: Sendable {
    public var speed: AsyncStream<Speed>? {
        nil
    }

    public var cadence: AsyncStream<Cadence>? {
        nil
    }

    internal init() {}

    public func disconnect() async throws -> DiscoveredSensor {
        throw DisconnectError.notImplemented
    }
}

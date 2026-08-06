import Foundation

public struct DiscoveredSensor: Sendable {
    public let id: UUID
    public let name: String?
    public let manufacturer: String?
    public let hasSpeed: Bool
    public let hasCadence: Bool

    internal init(
        id: UUID,
        name: String?,
        manufacturer: String?,
        hasSpeed: Bool,
        hasCadence: Bool
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.hasSpeed = hasSpeed
        self.hasCadence = hasCadence
    }

    public func connect() async throws -> ConnectedSensor {
        throw ConnectError.notImplemented
    }
}

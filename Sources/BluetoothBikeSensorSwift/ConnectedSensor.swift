import Foundation

public final class ConnectedSensor: Sendable {
    public var speed: AsyncStream<Speed>? {
        nil
    }

    public var cadence: AsyncStream<Cadence>? {
        nil
    }

    private let id: UUID
    private let name: String?
    private let manufacturer: String?
    private let hasSpeed: Bool
    private let hasCadence: Bool
    private let central: any BluetoothCentral

    package init(
        id: UUID,
        name: String?,
        manufacturer: String?,
        hasSpeed: Bool,
        hasCadence: Bool,
        central: any BluetoothCentral,
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.hasSpeed = hasSpeed
        self.hasCadence = hasCadence
        self.central = central
    }

    public func disconnect() async throws -> DiscoveredSensor {
        do {
            try await central.disconnect(id: id)
        } catch let error as BluetoothCentralError {
            throw BluetoothCentralErrorMapping.disconnectError(from: error)
        } catch {
            throw DisconnectError.failed(reason: error.localizedDescription)
        }

        return DiscoveredSensor(
            id: id,
            name: name,
            manufacturer: manufacturer,
            hasSpeed: hasSpeed,
            hasCadence: hasCadence,
            central: central,
        )
    }
}

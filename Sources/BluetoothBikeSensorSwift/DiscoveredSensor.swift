import Foundation

public struct DiscoveredSensor: Sendable {
    nonisolated(unsafe) package static var connectTimeoutNanoseconds: UInt64 = 10_000_000_000

    public let id: UUID
    public let name: String?
    public let manufacturer: String?
    public let hasSpeed: Bool
    public let hasCadence: Bool

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

    public func connect() async throws -> ConnectedSensor {
        guard await central.currentState == .poweredOn else {
            throw ConnectError.notPoweredOn
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await central.connect(id: id)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: Self.connectTimeoutNanoseconds)
                    throw ConnectError.timeout
                }

                try await group.next()
                group.cancelAll()
            }
        } catch let error as ConnectError {
            throw error
        } catch let error as BluetoothCentralError {
            throw BluetoothCentralErrorMapping.connectError(from: error)
        } catch {
            throw ConnectError.failed(reason: error.localizedDescription)
        }

        do {
            try await central.discoverServices(id: id, serviceUUIDs: [CSCS.serviceUUID])
        } catch {
            try? await central.disconnect(id: id)
            if let centralError = error as? BluetoothCentralError {
                throw BluetoothCentralErrorMapping.connectError(from: centralError)
            }
            throw ConnectError.serviceDiscoveryFailed(reason: error.localizedDescription)
        }

        return ConnectedSensor(
            id: id,
            name: name,
            manufacturer: manufacturer,
            hasSpeed: hasSpeed,
            hasCadence: hasCadence,
            central: central,
        )
    }
}

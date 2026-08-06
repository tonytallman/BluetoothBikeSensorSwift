import BluetoothBikeSensorSwift
import Foundation

struct SensorMetadata: Equatable, Sendable {
    let id: UUID
    let name: String?
    let manufacturer: String?
    let hasSpeed: Bool
    let hasCadence: Bool

    init(from sensor: DiscoveredSensor) {
        id = sensor.id
        name = sensor.name
        manufacturer = sensor.manufacturer
        hasSpeed = sensor.hasSpeed
        hasCadence = sensor.hasCadence
    }
}

enum SensorRowPhase: Equatable {
    case discovered
    case connecting
    case connected
}

@MainActor
@Observable
final class SensorRowModel: Identifiable {
    let metadata: SensorMetadata
    var phase: SensorRowPhase = .discovered
    var speedText: String?
    var cadenceText: String?

    private(set) var discoveredSensor: DiscoveredSensor
    private(set) var connectedSensor: ConnectedSensor?

    var id: UUID { metadata.id }

    init(discoveredSensor: DiscoveredSensor) {
        self.discoveredSensor = discoveredSensor
        metadata = SensorMetadata(from: discoveredSensor)
    }

    func applyConnected(_ sensor: ConnectedSensor) {
        connectedSensor = sensor
        phase = .connected
        speedText = sensor.speed == nil ? nil : "—"
        cadenceText = sensor.cadence == nil ? nil : "—"
    }

    func applyRediscovered(_ sensor: DiscoveredSensor) {
        discoveredSensor = sensor
        connectedSensor = nil
        phase = .discovered
        speedText = nil
        cadenceText = nil
    }

    func beginConnecting() {
        phase = .connecting
    }

    var supportsSpeed: Bool {
        connectedSensor?.speed != nil
    }

    var supportsCadence: Bool {
        connectedSensor?.cadence != nil
    }

    func updateSpeedDisplay(_ text: String?) {
        guard supportsSpeed else {
            speedText = nil
            return
        }
        speedText = text ?? "—"
    }

    func updateCadenceDisplay(_ text: String?) {
        guard supportsCadence else {
            cadenceText = nil
            return
        }
        cadenceText = text ?? "—"
    }
}

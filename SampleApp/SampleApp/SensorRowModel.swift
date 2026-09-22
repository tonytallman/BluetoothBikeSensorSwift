import BluetoothBikeSensorSwift
import Foundation

struct SensorMetadata: Equatable, Sendable {
    let id: UUID
    let name: String?
    let manufacturer: String?

    init(from sensor: DiscoveredSensor) {
        id = sensor.id
        name = sensor.name
        manufacturer = sensor.manufacturer
    }
}

enum SensorRowPhase: Equatable {
    case discovered
    case connecting
    case connected
}

enum ConnectedLocationPresentation: Equatable {
    case unavailable
    case fixed(String)
    case multiple(supported: [SensorLocation], current: SensorLocation)
}

@MainActor
@Observable
final class SensorRowModel: Identifiable {
    let metadata: SensorMetadata
    var phase: SensorRowPhase = .discovered
    var speedText: String?
    var cadenceText: String?
    var supportsSpeed = false
    var supportsCadence = false
    var locationPresentation: ConnectedLocationPresentation = .unavailable
    var selectedLocation: SensorLocation?

    private(set) var discoveredSensor: DiscoveredSensor
    private(set) var connectedSensor: ConnectedSensor?

    nonisolated var id: UUID { metadata.id }

    init(discoveredSensor: DiscoveredSensor) {
        self.discoveredSensor = discoveredSensor
        metadata = SensorMetadata(from: discoveredSensor)
    }

    func applyConnected(_ sensor: ConnectedSensor) {
        connectedSensor = sensor
        phase = .connected

        switch sensor.revolutions {
        case .wheel, .wheelAndCrank:
            supportsSpeed = true
            speedText = "—"
        case .crank:
            supportsSpeed = false
            speedText = nil
        }

        switch sensor.revolutions {
        case .crank, .wheelAndCrank:
            supportsCadence = true
            cadenceText = "—"
        case .wheel:
            supportsCadence = false
            cadenceText = nil
        }

        switch sensor.location {
        case .unavailable:
            locationPresentation = .unavailable
            selectedLocation = nil
        case let .fixed(location):
            locationPresentation = .fixed(location.displayName)
            selectedLocation = nil
        case let .multiple(locations):
            locationPresentation = .multiple(
                supported: locations.supported,
                current: locations.current,
            )
            selectedLocation = locations.current
        }
    }

    func applyRediscovered(_ sensor: DiscoveredSensor) {
        discoveredSensor = sensor
        connectedSensor = nil
        phase = .discovered
        speedText = nil
        cadenceText = nil
        supportsSpeed = false
        supportsCadence = false
        locationPresentation = .unavailable
        selectedLocation = nil
    }

    func beginConnecting() {
        phase = .connecting
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

    func syncMultipleLocationCurrent(_ location: SensorLocation) {
        guard case let .multiple(supported, _) = locationPresentation else { return }
        locationPresentation = .multiple(supported: supported, current: location)
        selectedLocation = location
    }
}

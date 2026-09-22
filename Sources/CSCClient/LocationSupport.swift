import Foundation

/// Sensor location support exposed by a connected sensor.
public enum LocationSupport: Sendable {
    case unavailable
    case fixed(SensorLocation)
    case multiple(MultipleSensorLocations)
}

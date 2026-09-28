internal import CSCWire
import Foundation

/// Multiple sensor locations supported by a connected CSCS sensor.
public final class MultipleSensorLocations: @unchecked Sendable {
    private let lock = NSLock()
    package let controlPoint: ControlPoint

    /// Sensor locations this peripheral supports.
    public let supported: [SensorLocation]

    private var _current: SensorLocation

    /// The sensor's current location assignment.
    public var current: SensorLocation {
        lock.lock()
        defer { lock.unlock() }
        return _current
    }

    init(
        supported: [SensorLocation],
        current: SensorLocation,
        controlPoint: ControlPoint,
    ) {
        self.supported = supported
        _current = current
        self.controlPoint = controlPoint
    }

    /// Updates the sensor location via the SC Control Point.
    ///
    /// - Parameter location: A location from this sensor's ``supported`` list.
    public func update(_ location: SensorLocation) async throws {
        guard supported.contains(location) else {
            throw ControlPointError.unsupportedLocation
        }

        _ = try await controlPoint.perform(.updateSensorLocation(location.assignedNumber))
        setCurrent(location)
    }

    private func setCurrent(_ location: SensorLocation) {
        lock.lock()
        _current = location
        lock.unlock()
    }
}

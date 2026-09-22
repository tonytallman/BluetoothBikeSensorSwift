package import CSCWire
import Foundation

/// Multiple sensor locations supported by a connected CSCS sensor.
public final class MultipleSensorLocations: @unchecked Sendable {
    private let lock = NSLock()
    private let controlPointSession: CSCControlPointSession

    /// Sensor locations this peripheral supports.
    public let supported: [SensorLocation]

    private var _current: SensorLocation

    /// The sensor's current location assignment.
    public var current: SensorLocation {
        lock.lock()
        defer { lock.unlock() }
        return _current
    }

    package init(
        supported: [SensorLocation],
        current: SensorLocation,
        controlPointSession: CSCControlPointSession,
    ) {
        self.supported = supported
        _current = current
        self.controlPointSession = controlPointSession
    }

    /// Updates the sensor location via the SC Control Point.
    ///
    /// - Parameter location: A location from this sensor's ``supported`` list.
    public func update(_ location: SensorLocation) async throws {
        guard supported.contains(location) else {
            throw ControlPointError.unsupportedLocation
        }

        let locationToApply = location
        try await controlPointSession.perform(
            request: CSCControlPointRequest.updateSensorLocation(location.assignedNumber).encode(),
            expectedRequestOpcode: CSCControlPointOpCode.updateSensorLocation.rawValue,
        ) { _ in
            setCurrent(locationToApply)
        }
    }

    private func setCurrent(_ location: SensorLocation) {
        lock.lock()
        _current = location
        lock.unlock()
    }
}

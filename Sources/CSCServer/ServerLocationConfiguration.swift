/// Build-time sensor-location configuration, fixed for the life of the `Server`.
package enum ServerLocationConfiguration: Sendable {
    case none
    /// Cached, read-only Sensor Location (`0x2A5D`) value; no SC Control Point involvement.
    case staticLocation(SensorLocationKind)
    /// Dynamic Sensor Location served from ``ServedSensorLocationBox``, updated via SC Control
    /// Point's Update Sensor Location procedure.
    case multiple(MultipleSensorLocationsConfiguration)
}

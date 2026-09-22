/// Supplies supported sensor locations and handles Update Sensor Location on SC Control Point.
public protocol MultipleSensorLocationsDelegate: Sendable {
    var supported: [SensorLocationKind] { get }
    var current: SensorLocationKind { get }
    func update(_ location: SensorLocationKind) async throws
}

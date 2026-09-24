/// Supplies supported sensor locations and handles Update Sensor Location on SC Control Point.
///
/// `supported` and `current` are read once inside ``ServerBuilder/multipleSensorLocations(_:)`` and are not read again.
/// ``Server/stop()`` cancels an in-flight `update` and waits until it returns; honor task cancellation.
/// A successful return is what the next ``Server/start()`` serves (the argument), even if `current` was not mutated.
/// A throw, including cancellation, leaves the served location unchanged.
///
/// The server cancels a call still running 30 seconds after the write was accepted. A call that
/// returns successfully after that has still been applied, and no indication is sent. The peer may
/// retry, so make your implementation safe to call again.
public protocol MultipleSensorLocationsDelegate: Sendable {
    var supported: [SensorLocationKind] { get }
    var current: SensorLocationKind { get }
    func update(_ location: SensorLocationKind) async throws
}

/// Snapshot of ``MultipleSensorLocationsDelegate/supported`` and `.current` taken once at
/// `build()`, paired with the delegate that handles Update Sensor Location.
package struct MultipleSensorLocationsConfiguration: Sendable {
    package let supported: [SensorLocationKind]
    package let current: SensorLocationKind
    package let delegate: any MultipleSensorLocationsDelegate
}

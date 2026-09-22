package struct MultipleSensorLocationsConfiguration: Sendable {
    package let supported: [SensorLocationKind]
    package let current: SensorLocationKind
    package let delegate: any MultipleSensorLocationsDelegate
}

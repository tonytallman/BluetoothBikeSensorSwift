package enum ServerLocationConfiguration: Sendable {
    case none
    case staticLocation(SensorLocationKind)
    case multiple(MultipleSensorLocationsConfiguration)
}

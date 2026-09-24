import CSCServer

@MainActor
protocol ControlPointEventSink: AnyObject, Sendable {
    func cumulativeWheelRevolutionsDidChange(to value: UInt32)
    func sensorLocationDidChange(to location: SensorLocationKind)
}

import CSCServer
@testable import SampleServerApp

@MainActor
final class FakeControlPointSink: ControlPointEventSink {
    private(set) var cumulativeValues: [UInt32] = []
    private(set) var locations: [SensorLocationKind] = []

    func cumulativeWheelRevolutionsDidChange(to value: UInt32) {
        cumulativeValues.append(value)
    }

    func sensorLocationDidChange(to location: SensorLocationKind) {
        locations.append(location)
    }
}

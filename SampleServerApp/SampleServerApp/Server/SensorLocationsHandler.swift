import CSCServer

struct SensorLocationsHandler: MultipleSensorLocationsDelegate {
    let supported: [SensorLocationKind]
    let current: SensorLocationKind
    weak var sink: (any ControlPointEventSink)?

    func update(_ location: SensorLocationKind) async throws {
        try Task.checkCancellation()
        let sink = sink
        await MainActor.run { [weak sink] in
            guard let sink else { return }
            sink.sensorLocationDidChange(to: location)
        }
    }
}

import Foundation

package final class MeasurementStateBox: @unchecked Sendable {
    private let lock = NSLock()
    var wheelCircumference: Measurement<UnitLength>
    var measurementState: CSCMeasurementState

    init(
        wheelCircumference: Measurement<UnitLength> = WheelRevolutions.defaultWheelCircumference,
        measurementState: CSCMeasurementState = CSCMeasurementState(),
    ) {
        self.wheelCircumference = wheelCircumference
        self.measurementState = measurementState
    }

    func readMeasurementContext() -> (circumferenceMeters: Double, state: CSCMeasurementState) {
        lock.lock()
        defer { lock.unlock() }
        return (
            wheelCircumference.converted(to: .meters).value,
            measurementState,
        )
    }

    func writeMeasurementState(_ state: CSCMeasurementState) {
        lock.lock()
        measurementState = state
        lock.unlock()
    }

    func readWheelCircumference() -> Measurement<UnitLength> {
        lock.lock()
        defer { lock.unlock() }
        return wheelCircumference
    }

    func writeWheelCircumference(_ value: Measurement<UnitLength>) {
        lock.lock()
        wheelCircumference = value
        lock.unlock()
    }

    func resetWheelBaseline() {
        lock.lock()
        measurementState.previousWheelRevolutions = nil
        measurementState.previousWheelEventTime = nil
        lock.unlock()
    }
}

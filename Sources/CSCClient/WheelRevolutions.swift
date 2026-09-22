package import CSCWire
import Foundation

/// Live wheel revolution measurements from a connected CSCS sensor.
public final class WheelRevolutions: Sendable {
    package static let defaultWheelCircumference = Measurement(value: 2.105, unit: UnitLength.meters)

    private let speedBroadcaster = StreamBroadcaster<Speed>()
    private let wheelSampleBroadcaster = StreamBroadcaster<WheelSample>()
    private let stateBox: MeasurementStateBox
    private let controlPointSession: CSCControlPointSession

    /// Wheel circumference used for speed calculation. Client-managed; not persisted by the library.
    public var wheelCircumference: Measurement<UnitLength> {
        get { stateBox.readWheelCircumference() }
        set { stateBox.writeWheelCircumference(newValue) }
    }

    /// Live speed stream. Emits ``Speed`` values while connected. The stream finishes on disconnect.
    public var speed: AsyncStream<Speed> {
        get async {
            await speedBroadcaster.makeStream()
        }
    }

    /// Wheel delta-sample stream derived from CSC wheel event timestamps.
    public var wheelSamples: AsyncStream<WheelSample> {
        get async {
            await wheelSampleBroadcaster.makeStream()
        }
    }

    package init(
        stateBox: MeasurementStateBox,
        controlPointSession: CSCControlPointSession,
    ) {
        self.stateBox = stateBox
        self.controlPointSession = controlPointSession
    }

    /// Sets the sensor's cumulative wheel revolutions via the SC Control Point.
    ///
    /// Success clears the local wheel delta baseline so the next measurement establishes a new baseline.
    public func setCumulativeRevolutions(_ value: UInt32) async throws {
        let stateBox = stateBox
        try await controlPointSession.perform(
            request: CSCControlPointRequest.setCumulativeValue(value).encode(),
            expectedRequestOpcode: CSCControlPointOpCode.setCumulativeValue.rawValue,
        ) { _ in
            stateBox.resetWheelBaseline()
        }
    }

    package func finishStreams() async {
        await speedBroadcaster.finish()
        await wheelSampleBroadcaster.finish()
    }

    package func yieldSpeed(_ speed: Speed) async {
        await speedBroadcaster.yield(speed)
    }

    package func yieldWheelSample(_ sample: WheelSample) async {
        await wheelSampleBroadcaster.yield(sample)
    }
}

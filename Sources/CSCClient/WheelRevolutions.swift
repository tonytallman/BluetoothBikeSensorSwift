internal import CSCWire
import Foundation

public typealias Speed = Measurement<UnitSpeed>

public struct WheelSample: Sendable, Equatable {
    public let deltaDistance: Measurement<UnitLength>
    public let deltaTime: Measurement<UnitDuration>
}

/// Live wheel revolution measurements from a connected CSCS sensor.
public final class WheelRevolutions: Sendable {
    package static let defaultWheelCircumference = Measurement(value: 2.105, unit: UnitLength.meters)

    private let speedBroadcaster = StreamBroadcaster<Speed>()
    private let wheelSampleBroadcaster = StreamBroadcaster<WheelSample>()
    private let controlPoint: ControlPoint?
    private let lock = NSLock()
    private nonisolated(unsafe) var circumference = defaultWheelCircumference
    private nonisolated(unsafe) var baseline = RevolutionBaseline<UInt32>()

    public var wheelCircumference: Measurement<UnitLength> {
        get {
            lock.withLock { circumference }
        }
        set {
            lock.withLock {
                circumference = newValue
            }
        }
    }

    public var speed: AsyncStream<Speed> {
        get async {
            await speedBroadcaster.makeStream()
        }
    }

    public var wheelSamples: AsyncStream<WheelSample> {
        get async {
            await wheelSampleBroadcaster.makeStream()
        }
    }

    package init(controlPoint: ControlPoint?) {
        self.controlPoint = controlPoint
    }

    package func receive(revolutions: UInt32, eventTime: UInt16) async {
        let sample: WheelSample? = lock.withLock {
            guard let delta = baseline.delta(revolutions: revolutions, eventTime: eventTime) else {
                return nil
            }
            let circumferenceMeters = circumference.converted(to: .meters).value
            return Self.sample(
                revolutions: delta.revolutions,
                seconds: delta.seconds,
                circumferenceMeters: circumferenceMeters,
            )
        }

        guard let sample else {
            return
        }

        let speedMetersPerSecond = sample.deltaDistance.converted(to: .meters).value
            / sample.deltaTime.converted(to: .seconds).value
        await speedBroadcaster.yield(Measurement(value: speedMetersPerSecond, unit: .metersPerSecond))
        await wheelSampleBroadcaster.yield(sample)
    }

    public func setCumulativeRevolutions(_ value: UInt32) async throws {
        guard let controlPoint else {
            throw ControlPointError.controlPointUnavailable
        }
        _ = try await controlPoint.perform(.setCumulativeValue(value))
        lock.withLock {
            baseline.reset()
        }
    }

    package static func sample(
        revolutions: UInt32,
        seconds: Double,
        circumferenceMeters: Double,
    ) -> WheelSample? {
        let speed = Double(revolutions) * circumferenceMeters / seconds
        guard speed <= 50 else {
            return nil
        }
        return WheelSample(
            deltaDistance: Measurement(
                value: Double(revolutions) * circumferenceMeters,
                unit: .meters,
            ),
            deltaTime: Measurement(value: seconds, unit: .seconds),
        )
    }

    package func finishStreams() async {
        await speedBroadcaster.finish()
        await wheelSampleBroadcaster.finish()
    }
}

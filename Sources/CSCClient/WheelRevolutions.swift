internal import CSCWire
import Foundation

/// Instantaneous speed from a CSCS sensor, as ``Measurement`` in ``UnitSpeed``.
public typealias Speed = Measurement<UnitSpeed>

/// A wheel rotation delta between two CSC measurement notifications.
///
/// `deltaDistance` is derived from revolution count and the client-managed
/// ``WheelRevolutions/wheelCircumference`` at emission time. `deltaTime` comes
/// from CSC last-wheel-event timestamps (1/1024 s resolution), not BLE arrival time.
public struct WheelSample: Sendable, Equatable {
    /// Distance traveled during this interval, always in meters.
    public let deltaDistance: Measurement<UnitLength>

    /// Elapsed time between CSC wheel event timestamps for this interval.
    public let deltaTime: Measurement<UnitDuration>
}

/// Live wheel revolution measurements from a connected CSCS sensor.
public final class WheelRevolutions: Sendable {
    static let defaultWheelCircumference = Measurement(value: 2.105, unit: UnitLength.meters)

    private let speedBroadcaster = StreamBroadcaster<Speed>()
    private let wheelSampleBroadcaster = StreamBroadcaster<WheelSample>()
    private let controlPoint: ControlPoint?
    private let lock = NSLock()
    private nonisolated(unsafe) var circumference = defaultWheelCircumference
    private nonisolated(unsafe) var baseline = RevolutionBaseline<UInt32>()

    /// Wheel circumference used for speed calculation. Client-managed; not persisted by the library.
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

    init(controlPoint: ControlPoint?) {
        self.controlPoint = controlPoint
    }

    func receive(revolutions: UInt32, eventTime: UInt16) async {
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

    /// Throws ``ControlPointError/controlPointUnavailable`` when SC Control Point was not discovered.
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

    func finishStreams() async {
        await speedBroadcaster.finish()
        await wheelSampleBroadcaster.finish()
    }
}

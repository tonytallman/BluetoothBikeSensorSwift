internal import CSCWire
import Foundation

/// Instantaneous cadence from a CSCS sensor, as ``Measurement`` in ``UnitFrequency``.
///
/// Use ``UnitFrequency/revolutionsPerMinute`` for RPM values.
public typealias Cadence = Measurement<UnitFrequency>

extension UnitFrequency {
    /// Revolutions per minute for CSC cadence values.
    public static let revolutionsPerMinute = UnitFrequency(
        symbol: "rpm",
        converter: UnitConverterLinear(coefficient: 1.0 / 60.0),
    )
}

/// A crank rotation delta between two CSC measurement notifications.
///
/// `deltaTime` comes from CSC last-crank-event timestamps (1/1024 s resolution),
/// not BLE arrival time.
public struct CrankSample: Sendable, Equatable {
    /// Crank revolutions during this interval.
    public let deltaRevolutions: Int

    /// Elapsed time between CSC crank event timestamps for this interval.
    public let deltaTime: Measurement<UnitDuration>
}

/// Live crank revolution measurements from a connected CSCS sensor.
///
/// The baseline is `nonisolated(unsafe)` behind `lock` so this `Sendable` class can store it.
/// Only the measurement loop touches it. The lock is not held across the broadcaster awaits.
///
/// The first sample only seeds the baseline. A later sample is emitted when the event-time
/// delta is nonzero and the implied cadence is at most 300 rpm. A faster delta is not emitted,
/// but the baseline has already moved to that sample. Streams do not replay. After
/// ``finishStreams()``, a new subscriber sees a finished stream.
public final class CrankRevolutions: Sendable {
    private let cadenceBroadcaster = StreamBroadcaster<Cadence>()
    private let crankSampleBroadcaster = StreamBroadcaster<CrankSample>()
    private let lock = NSLock()
    private nonisolated(unsafe) var baseline = RevolutionBaseline<UInt16>()

    /// Live cadence in revolutions per minute. The stream finishes on disconnect. Subscribing
    /// is async because the underlying broadcaster is an actor. A subscriber sees only later samples.
    public var cadence: AsyncStream<Cadence> {
        get async {
            await cadenceBroadcaster.makeStream()
        }
    }

    /// Crank delta-sample stream derived from CSC crank event timestamps.
    public var crankSamples: AsyncStream<CrankSample> {
        get async {
            await crankSampleBroadcaster.makeStream()
        }
    }

    init() {}

    /// Applies one CSC crank half. The baseline update happens under `lock` before any await.
    /// Cadence is yielded before the matching ``CrankSample``. A `nil` sample (first packet,
    /// zero event-time delta, or cadence above 300 rpm) yields nothing.
    func receive(revolutions: UInt16, eventTime: UInt16) async {
        let sample: CrankSample? = lock.withLock {
            guard let delta = baseline.delta(revolutions: revolutions, eventTime: eventTime) else {
                return nil
            }
            return Self.sample(revolutions: delta.revolutions, seconds: delta.seconds)
        }

        guard let sample else {
            return
        }

        let rpm = Double(sample.deltaRevolutions) / sample.deltaTime.converted(to: .seconds).value * 60.0
        await cadenceBroadcaster.yield(Measurement(value: rpm, unit: .revolutionsPerMinute))
        await crankSampleBroadcaster.yield(sample)
    }

    /// Builds a sample when implied cadence is at most 300 rpm, including exactly 300. The
    /// caller has already advanced the baseline.
    package static func sample(revolutions: UInt16, seconds: Double) -> CrankSample? {
        let cadence = Double(revolutions) / seconds * 60.0
        guard cadence <= 300 else {
            return nil
        }
        return CrankSample(
            deltaRevolutions: Int(revolutions),
            deltaTime: Measurement(value: seconds, unit: .seconds),
        )
    }

    func finishStreams() async {
        await cadenceBroadcaster.finish()
        await crankSampleBroadcaster.finish()
    }
}

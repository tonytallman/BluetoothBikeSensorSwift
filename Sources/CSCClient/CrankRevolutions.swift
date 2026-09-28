internal import CSCWire
import Foundation

public typealias Cadence = Measurement<UnitFrequency>

extension UnitFrequency {
    public static let revolutionsPerMinute = UnitFrequency(
        symbol: "rpm",
        converter: UnitConverterLinear(coefficient: 1.0 / 60.0),
    )
}

/// A crank rotation delta between two CSC measurement notifications.
public struct CrankSample: Sendable, Equatable {
    public let deltaRevolutions: Int
    public let deltaTime: Measurement<UnitDuration>
}

/// Live crank revolution measurements from a connected CSCS sensor.
public final class CrankRevolutions: Sendable {
    private let cadenceBroadcaster = StreamBroadcaster<Cadence>()
    private let crankSampleBroadcaster = StreamBroadcaster<CrankSample>()
    private let lock = NSLock()
    private nonisolated(unsafe) var baseline = RevolutionBaseline<UInt16>()

    /// Live cadence stream in revolutions per minute. The stream finishes on disconnect.
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

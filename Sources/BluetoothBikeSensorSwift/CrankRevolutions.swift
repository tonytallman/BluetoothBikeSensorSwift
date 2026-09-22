import Foundation

/// Live crank revolution measurements from a connected CSCS sensor.
public final class CrankRevolutions: Sendable {
    private let cadenceBroadcaster = StreamBroadcaster<Cadence>()
    private let crankSampleBroadcaster = StreamBroadcaster<CrankSample>()

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

    package init() {}

    package func finishStreams() async {
        await cadenceBroadcaster.finish()
        await crankSampleBroadcaster.finish()
    }

    package func yieldCadence(_ cadence: Cadence) async {
        await cadenceBroadcaster.yield(cadence)
    }

    package func yieldCrankSample(_ sample: CrankSample) async {
        await crankSampleBroadcaster.yield(sample)
    }
}

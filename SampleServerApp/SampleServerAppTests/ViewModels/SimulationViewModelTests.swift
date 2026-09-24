import CSCServer
import Testing
@testable import SampleServerApp

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RuntimeSimulationViewModelTests {
    @Test func automaticWheelTickYield() async {
        let time = ManualTimeSource()
        let ticker = ManualTicker()
        let simulation = RuntimeSimulationViewModel(timeSource: time, ticker: ticker)
        var outputs = SimulationOutputs()
        let streamPair = AsyncStream.makeStream(
            of: WheelRevolution.self,
            bufferingPolicy: .bufferingNewest(1),
        )
        outputs.wheelContinuation = streamPair.continuation
        simulation.begin(outputs, showsWheel: true, showsCrank: false)
        time.elapsed = .seconds(1)
        ticker.tick()
        var iterator = streamPair.stream.makeAsyncIterator()
        let sample = await iterator.next()
        #expect(sample?.cumulativeRevolutions == 3)
        #expect(sample?.lastEventTime == 931)
        simulation.end()
        ticker.finish()
    }

    @Test func nothingBeforeBeginOrAfterEnd() async {
        let ticker = ManualTicker()
        let simulation = RuntimeSimulationViewModel(ticker: ticker)
        let pair = AsyncStream.makeStream(of: WheelRevolution.self, bufferingPolicy: .bufferingNewest(1))
        ticker.tick()
        var iterator = pair.stream.makeAsyncIterator()
        let before = await iterator.next()
        #expect(before == nil)
        var outputs = SimulationOutputs()
        outputs.wheelContinuation = pair.continuation
        simulation.begin(outputs, showsWheel: true, showsCrank: false)
        simulation.end()
        ticker.tick()
        let after = await iterator.next()
        #expect(after == nil)
        ticker.finish()
    }

    @Test func setCumulativeUpdatesNextSample() async {
        let time = ManualTimeSource()
        let ticker = ManualTicker()
        let simulation = RuntimeSimulationViewModel(timeSource: time, ticker: ticker)
        var outputs = SimulationOutputs()
        let pair = AsyncStream.makeStream(of: WheelRevolution.self, bufferingPolicy: .bufferingNewest(1))
        outputs.wheelContinuation = pair.continuation
        simulation.begin(outputs, showsWheel: true, showsCrank: false)
        simulation.setCumulativeWheelRevolutions(1000)
        time.elapsed = .seconds(1)
        ticker.tick()
        var iterator = pair.stream.makeAsyncIterator()
        let sample = await iterator.next()
        #expect((sample?.cumulativeRevolutions ?? 0) >= 1000)
        simulation.end()
        ticker.finish()
    }

    @Test func pauseSkipsTickSample() async {
        let time = ManualTimeSource()
        let ticker = ManualTicker()
        let simulation = RuntimeSimulationViewModel(timeSource: time, ticker: ticker)
        var outputs = SimulationOutputs()
        let pair = AsyncStream.makeStream(of: WheelRevolution.self, bufferingPolicy: .bufferingNewest(1))
        outputs.wheelContinuation = pair.continuation
        simulation.begin(outputs, showsWheel: true, showsCrank: false)
        simulation.pause()
        time.elapsed = .seconds(1)
        ticker.tick()
        var iterator = pair.stream.makeAsyncIterator()
        let pausedSample = await iterator.next()
        #expect(pausedSample == nil)
        simulation.resume()
        time.elapsed = .seconds(2)
        ticker.tick()
        let sample = await iterator.next()
        #expect(sample != nil)
        simulation.end()
        ticker.finish()
    }
}

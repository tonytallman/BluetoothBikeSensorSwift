import CSCServer
import Testing
@testable import SampleServerApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
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
        await Task.yield()
        var iterator = streamPair.stream.makeAsyncIterator()
        time.elapsed = .seconds(1)
        ticker.tick()
        let sample = await iterator.next()
        #expect(sample?.cumulativeRevolutions == 3)
        #expect(sample?.lastEventTime == 931)
        simulation.end()
        ticker.finish()
    }

    @Test func nothingBeforeBeginOrAfterEnd() async {
        let time = ManualTimeSource()
        let ticker = ManualTicker()
        let simulation = RuntimeSimulationViewModel(timeSource: time, ticker: ticker)
        let pair = AsyncStream.makeStream(of: WheelRevolution.self, bufferingPolicy: .bufferingNewest(1))
        var outputs = SimulationOutputs()
        outputs.wheelContinuation = pair.continuation
        simulation.begin(outputs, showsWheel: true, showsCrank: false)
        await Task.yield()
        var iterator = pair.stream.makeAsyncIterator()
        simulation.end()
        time.elapsed = .seconds(1)
        simulation.tick()
        pair.continuation.finish()
        #expect(await iterator.next() == nil)
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
        await Task.yield()
        var iterator = pair.stream.makeAsyncIterator()
        time.elapsed = .seconds(1)
        ticker.tick()
        let sample = await iterator.next()
        #expect((sample?.cumulativeRevolutions ?? 0) >= 1000)
        simulation.end()
        ticker.finish()
    }

    @Test func pauseSkipsTickSample() async {
        let time = ManualTimeSource()
        let simulation = RuntimeSimulationViewModel(timeSource: time)
        var outputs = SimulationOutputs()
        let pair = AsyncStream.makeStream(of: WheelRevolution.self, bufferingPolicy: .bufferingNewest(1))
        outputs.wheelContinuation = pair.continuation
        let period = RevolutionPeriod.wheelPeriod(
            speedKilometersPerHour: 25,
            circumferenceMeters: 2.105,
        )
        simulation.begin(outputs, showsWheel: true, showsCrank: false)
        simulation.pause()
        time.elapsed = .seconds(5)
        let readoutBeforePauseTick = simulation.wheelReadout
        simulation.tick()
        #expect(simulation.wheelReadout == readoutBeforePauseTick)
        simulation.resume()
        time.elapsed = .seconds(10)
        var iterator = pair.stream.makeAsyncIterator()
        simulation.tick()
        let sample = await iterator.next()
        var schedule = RevolutionSchedule()
        schedule.beginAutomatic(at: .zero, period: period)
        let expected = schedule.advance(to: .seconds(5))
        #expect(sample?.cumulativeRevolutions == UInt32(truncatingIfNeeded: expected!.cumulative))
        #expect(sample?.lastEventTime == expected?.wheelRevolution.lastEventTime)
        simulation.end()
    }

    @Test func automaticBothMetricsTickYieldsOneCombinedElement() async {
        let time = ManualTimeSource()
        let ticker = ManualTicker()
        let simulation = RuntimeSimulationViewModel(timeSource: time, ticker: ticker)
        var outputs = SimulationOutputs()
        let pair = AsyncStream.makeStream(
            of: WheelAndCrankRevolution.self,
            bufferingPolicy: .bufferingNewest(1),
        )
        outputs.wheelAndCrankContinuation = pair.continuation
        simulation.begin(outputs, showsWheel: true, showsCrank: true)
        await Task.yield()
        var iterator = pair.stream.makeAsyncIterator()
        time.elapsed = .seconds(1)
        ticker.tick()
        let sample = await iterator.next()
        let wheelPeriod = RevolutionPeriod.wheelPeriod(
            speedKilometersPerHour: 25,
            circumferenceMeters: 2.105,
        )
        let crankPeriod = RevolutionPeriod.crankPeriod(revolutionsPerMinute: 90)
        var wheelSchedule = RevolutionSchedule()
        var crankSchedule = RevolutionSchedule()
        wheelSchedule.beginAutomatic(at: .zero, period: wheelPeriod)
        crankSchedule.beginAutomatic(at: .zero, period: crankPeriod)
        let expectedWheel = wheelSchedule.advance(to: .seconds(1))!.wheelRevolution
        let expectedCrank = crankSchedule.advance(to: .seconds(1))!.crankRevolution
        #expect(sample?.wheel == expectedWheel)
        #expect(sample?.crank == expectedCrank)
        simulation.end()
        ticker.finish()
    }

    @Test func automaticWheelWithManualCrankYieldsWheelOnlyElement() async {
        let time = ManualTimeSource()
        let ticker = ManualTicker()
        let simulation = RuntimeSimulationViewModel(timeSource: time, ticker: ticker)
        simulation.crankMode = .manual
        var outputs = SimulationOutputs()
        let pair = AsyncStream.makeStream(
            of: WheelAndCrankRevolution.self,
            bufferingPolicy: .bufferingNewest(1),
        )
        outputs.wheelAndCrankContinuation = pair.continuation
        simulation.begin(outputs, showsWheel: true, showsCrank: true)
        await Task.yield()
        var iterator = pair.stream.makeAsyncIterator()
        time.elapsed = .seconds(1)
        ticker.tick()
        let sample = await iterator.next()
        #expect(sample?.wheel != nil)
        #expect(sample?.crank == nil)
        simulation.end()
        ticker.finish()
    }

    @Test func manualWheelBeforeCrankEventYieldsWheelOnlyHalf() async {
        let simulation = RuntimeSimulationViewModel()
        var outputs = SimulationOutputs()
        let pair = AsyncStream.makeStream(
            of: WheelAndCrankRevolution.self,
            bufferingPolicy: .bufferingNewest(1),
        )
        outputs.wheelAndCrankContinuation = pair.continuation
        simulation.begin(outputs, showsWheel: true, showsCrank: true)
        simulation.wheelMode = .manual
        simulation.crankMode = .manual
        simulation.addWheelRevolution()
        await Task.yield()
        var iterator = pair.stream.makeAsyncIterator()
        let sample = await iterator.next()
        #expect(sample?.wheel != nil)
        #expect(sample?.crank == nil)
        simulation.end()
    }

    @Test func endFinishesCombinedStream() async {
        let simulation = RuntimeSimulationViewModel()
        var outputs = SimulationOutputs()
        let pair = AsyncStream.makeStream(
            of: WheelAndCrankRevolution.self,
            bufferingPolicy: .bufferingNewest(1),
        )
        outputs.wheelAndCrankContinuation = pair.continuation
        simulation.begin(outputs, showsWheel: true, showsCrank: true)
        simulation.end()
        outputs.finish()
        var iterator = pair.stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }
}

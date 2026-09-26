import CSCServer
import Testing
@testable import SampleServerApp

@Suite struct RevolutionScheduleTests {
    @Test func automaticDoesNotFireAtStartInstant() {
        var schedule = RevolutionSchedule()
        schedule.beginAutomatic(at: .zero, period: .seconds(0.30312))
        #expect(schedule.advance(to: .zero) == nil)
    }

    @Test func wheelSamplesAtOneAndTwoSeconds() {
        var schedule = RevolutionSchedule()
        let period = RevolutionPeriod.wheelPeriod(
            speedKilometersPerHour: 25,
            circumferenceMeters: 2.105,
        )
        schedule.beginAutomatic(at: .zero, period: period)
        let first = schedule.advance(to: .seconds(1))
        #expect(first?.cumulative == 3)
        #expect(first?.wheelRevolution.lastEventTime == 931)
        let second = schedule.advance(to: .seconds(2))
        #expect(second?.cumulative == 6)
        #expect(second?.wheelRevolution.lastEventTime == 1862)
    }

    @Test func clientDisplayAfterBaselineSample() {
        var schedule = RevolutionSchedule()
        let period = RevolutionPeriod.wheelPeriod(
            speedKilometersPerHour: 25,
            circumferenceMeters: 2.105,
        )
        schedule.beginAutomatic(at: .zero, period: period)
        let baseline = schedule.advance(to: .seconds(1))!.wheelRevolution
        let current = schedule.advance(to: .seconds(2))!.wheelRevolution
        let speed = ClientFormula.speedKilometersPerHour(
            previousCumulative: baseline.cumulativeRevolutions,
            previousEventTime: baseline.lastEventTime,
            currentCumulative: current.cumulativeRevolutions,
            currentEventTime: current.lastEventTime,
            circumferenceMeters: 2.105,
        )
        #expect(speed != nil)
        #expect(abs(speed! - 25.0) < 0.05)
    }

    @Test func crankNinetyRPMClientDisplay() {
        let baseline = CrankRevolution(cumulativeRevolutions: 1, lastEventTime: 683)
        let current = CrankRevolution(cumulativeRevolutions: 3, lastEventTime: 2048)
        let cadence = ClientFormula.cadenceRPM(
            previousCumulative: baseline.cumulativeRevolutions,
            previousEventTime: baseline.lastEventTime,
            currentCumulative: current.cumulativeRevolutions,
            currentEventTime: current.lastEventTime,
        )
        #expect(cadence != nil)
        #expect(abs(cadence! - 90.0) < 0.3)
    }

    @Test func advanceBeforeFirstPeriodReturnsFalse() {
        var schedule = RevolutionSchedule()
        schedule.beginAutomatic(at: .zero, period: .seconds(1))
        #expect(schedule.advance(to: .milliseconds(500)) == nil)
    }

    @Test func periodChangeReschedulesFromAnchor() {
        var schedule = RevolutionSchedule()
        schedule.beginAutomatic(at: .zero, period: .seconds(1))
        _ = schedule.advance(to: .seconds(1))
        schedule.setPeriod(.milliseconds(500), at: .seconds(1))
        let sample = schedule.advance(to: .seconds(1.5))
        #expect(sample != nil)
    }

    @Test func manualRevolutionUsesNow() {
        var schedule = RevolutionSchedule()
        schedule.beginAutomatic(at: .zero, period: .seconds(1))
        schedule.stopAutomatic()
        let sample = schedule.manualRevolution(at: .seconds(3))
        #expect(sample.lastEventElapsed == .seconds(3))
    }

    @Test func setCumulativeKeepsEventTime() {
        var schedule = RevolutionSchedule()
        schedule.beginAutomatic(at: .zero, period: .seconds(1))
        let sample = schedule.advance(to: .seconds(1))
        let event = sample!.lastEventElapsed
        schedule.setCumulativeRevolutions(1000)
        #expect(schedule.cumulative == 1000)
        #expect(schedule.lastEventElapsed == event)
    }

    @Test func crankCounterTruncatesToUInt16() {
        var schedule = RevolutionSchedule()
        schedule.setCumulativeRevolutions(65535)
        let sample = schedule.manualRevolution(at: .seconds(1))
        #expect(sample.crankRevolution.cumulativeRevolutions == 0)
        let next = schedule.manualRevolution(at: .seconds(2))
        #expect(next.crankRevolution.cumulativeRevolutions == 1)
    }
}

import CSCServer

private func abs(_ value: Double) -> Double {
    value < 0 ? -value : value
}

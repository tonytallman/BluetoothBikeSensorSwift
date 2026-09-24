import Testing
@testable import SampleServerApp

@Suite(.serialized) struct RevolutionPeriodTests {
    @Test func wheelAtTwentyFiveKilometersPerHour() {
        let period = RevolutionPeriod.wheelPeriod(
            speedKilometersPerHour: 25,
            circumferenceMeters: 2.105,
        )
        #expect(abs(durationSeconds(period) - 0.30312) < 0.001)
    }

    @Test func wheelAtSixtyKilometersPerHour() {
        let period = RevolutionPeriod.wheelPeriod(
            speedKilometersPerHour: 60,
            circumferenceMeters: 2.105,
        )
        #expect(abs(durationSeconds(period) - 0.1263) < 0.001)
    }

    @Test func crankAtNinetyRPM() {
        let period = RevolutionPeriod.crankPeriod(revolutionsPerMinute: 90)
        #expect(abs(durationSeconds(period) - 0.6667) < 0.001)
    }

    @Test func crankAtOneTwentyRPM() {
        let period = RevolutionPeriod.crankPeriod(revolutionsPerMinute: 120)
        #expect(abs(durationSeconds(period) - 0.5) < 0.0001)
    }
}

private func abs(_ value: Double) -> Double {
    value < 0 ? -value : value
}

private func durationSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}

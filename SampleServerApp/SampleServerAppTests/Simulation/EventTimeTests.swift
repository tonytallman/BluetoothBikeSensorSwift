import Testing
@testable import SampleServerApp

@Suite struct EventTimeTests {
    @Test func zero() {
        #expect(EventTime.wireValue(for: .zero) == 0)
    }

    @Test func halfSecond() {
        #expect(EventTime.wireValue(for: .seconds(0.5)) == 512)
    }

    @Test func oneSecond() {
        #expect(EventTime.wireValue(for: .seconds(1)) == 1024)
    }

    @Test func almostSixtyFourSeconds() {
        #expect(EventTime.wireValue(for: .seconds(63.999)) == 65535)
    }

    @Test func sixtyFourSecondsWraps() {
        #expect(EventTime.wireValue(for: .seconds(64)) == 0)
    }

    @Test func sixtyFiveSeconds() {
        #expect(EventTime.wireValue(for: .seconds(65)) == 1024)
    }

    @Test func halfTickRoundingUp() {
        #expect(EventTime.wireValue(for: .seconds(1.0 / 2048.0)) == 1)
    }

    @Test func halfTickRoundingDown() {
        let oneTick = Duration.seconds(1) / 2048
        let almost = oneTick - Duration.nanoseconds(1)
        #expect(EventTime.wireValue(for: almost) == 0)
    }

    @Test func wireValueDoesNotTrapUpToInt64MaxSeconds() {
        let large = Int64.max / 1024
        #expect(EventTime.wireValue(for: .seconds(large)) == 64512)
        #expect(EventTime.wireValue(for: .seconds(large + 1)) == 0)
        #expect(EventTime.wireValue(for: .seconds(Int64.max)) == 64512)
    }
}

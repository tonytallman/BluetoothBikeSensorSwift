import CSCClient
import Testing

@Suite(.timeLimit(.minutes(1))) struct RevolutionBaselineTests {
    @Test func firstPacketSeeds() {
        var baseline = RevolutionBaseline<UInt32>()
        #expect(baseline.delta(revolutions: 100, eventTime: 1_024) == nil)

        var crankBaseline = RevolutionBaseline<UInt16>()
        #expect(crankBaseline.delta(revolutions: 10, eventTime: 1_024) == nil)
    }

    @Test func zeroDeltaTimeDoesNotEmit() {
        var baseline = RevolutionBaseline<UInt32>()
        _ = baseline.delta(revolutions: 100, eventTime: 1_024)
        #expect(baseline.delta(revolutions: 101, eventTime: 1_024) == nil)

        var crankBaseline = RevolutionBaseline<UInt16>()
        _ = crankBaseline.delta(revolutions: 10, eventTime: 1_024)
        #expect(crankBaseline.delta(revolutions: 11, eventTime: 1_024) == nil)
    }

    @Test func handlesRevolutionWraparound() {
        var wheelBaseline = RevolutionBaseline<UInt32>()
        _ = wheelBaseline.delta(revolutions: UInt32.max - 1, eventTime: 1_024)
        let wheelDelta = wheelBaseline.delta(revolutions: 1, eventTime: 2_048)
        #expect(wheelDelta?.revolutions == 3)

        var crankBaseline = RevolutionBaseline<UInt16>()
        _ = crankBaseline.delta(revolutions: UInt16.max, eventTime: 1_024)
        let crankDelta = crankBaseline.delta(revolutions: 0, eventTime: 2_048)
        #expect(crankDelta?.revolutions == 1)
    }

    @Test func eventTimeWraps() {
        var wheelBaseline = RevolutionBaseline<UInt32>()
        _ = wheelBaseline.delta(revolutions: 100, eventTime: 65_500)
        let wheelDelta = wheelBaseline.delta(revolutions: 101, eventTime: 100)
        let expected = Double(UInt16(100) &- UInt16(65_500)) / 1024.0
        #expect(abs((wheelDelta?.seconds ?? 0) - expected) < 0.0001)

        var crankBaseline = RevolutionBaseline<UInt16>()
        _ = crankBaseline.delta(revolutions: 10, eventTime: 65_500)
        let crankDelta = crankBaseline.delta(revolutions: 11, eventTime: 100)
        #expect(abs((crankDelta?.seconds ?? 0) - expected) < 0.0001)
    }
}

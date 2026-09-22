import CSCClient
import CSCWire
import Foundation
import Testing

@Suite struct CSCMeasurementParserTests {
    private let defaultCircumference = 2.105

    private func wheelSample(revolutions: UInt32, eventTime: UInt16) -> CSCMeasurement {
        CSCMeasurement.decode(
            CSCMeasurementFixtures.wheelMeasurement(revolutions: revolutions, eventTime: eventTime),
        )!
    }

    private func crankSample(revolutions: UInt16, eventTime: UInt16) -> CSCMeasurement {
        CSCMeasurement.decode(
            CSCMeasurementFixtures.crankMeasurement(revolutions: revolutions, eventTime: eventTime),
        )!
    }

    @Test func wheelDeltaHappyPath() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 100, eventTime: 1_024),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )

        let delta = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 102, eventTime: 2_048),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )

        #expect(delta?.deltaRevolutions == 2)
        #expect(delta?.deltaTimeSeconds == 1.0)
        let speed = CSCMeasurementParser.speed(from: delta!, circumferenceMeters: defaultCircumference)
        #expect(speed.value == 4.21)
        #expect(speed.unit == .metersPerSecond)
    }

    @Test func crankDeltaHappyPath() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 10, eventTime: 1_024),
            previous: &state,
        )

        let delta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 11, eventTime: 2_048),
            previous: &state,
        )

        #expect(delta?.deltaRevolutions == 1)
        #expect(delta?.deltaTimeSeconds == 1.0)
        let cadence = CSCMeasurementParser.cadence(from: delta!)
        #expect(cadence.value == 60.0)
        #expect(cadence.unit == .revolutionsPerMinute)
    }

    @Test func firstPacketSeeds() {
        var state = CSCMeasurementState()

        let wheelDelta = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 100, eventTime: 1_024),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )
        #expect(wheelDelta == nil)
        #expect(state.previousWheelRevolutions == 100)
        #expect(state.previousWheelEventTime == 1_024)

        var crankState = CSCMeasurementState()
        let crankDelta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 10, eventTime: 1_024),
            previous: &crankState,
        )
        #expect(crankDelta == nil)
        #expect(crankState.previousCrankRevolutions == 10)
        #expect(crankState.previousCrankEventTime == 1_024)
    }

    @Test func zeroDeltaTimeDoesNotEmit() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 100, eventTime: 1_024),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )

        let delta = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 101, eventTime: 1_024),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )

        #expect(delta == nil)
        #expect(state.previousWheelRevolutions == 101)
        #expect(state.previousWheelEventTime == 1_024)
    }

    @Test func zeroDeltaTimeDoesNotEmitCrank() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 10, eventTime: 1_024),
            previous: &state,
        )

        let delta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 11, eventTime: 1_024),
            previous: &state,
        )

        #expect(delta == nil)
        #expect(state.previousCrankRevolutions == 11)
        #expect(state.previousCrankEventTime == 1_024)
    }

    @Test func zeroQuantityWithPositiveDeltaTimeEmitsWheel() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 100, eventTime: 1_024),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )

        let delta = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 100, eventTime: 2_048),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )

        #expect(delta?.deltaRevolutions == 0)
        #expect(delta?.deltaTimeSeconds == 1.0)
        let speed = CSCMeasurementParser.speed(from: delta!, circumferenceMeters: defaultCircumference)
        #expect(speed.value == 0.0)
    }

    @Test func zeroQuantityWithPositiveDeltaTimeEmitsCrank() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 10, eventTime: 1_024),
            previous: &state,
        )

        let delta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 10, eventTime: 2_048),
            previous: &state,
        )

        #expect(delta?.deltaRevolutions == 0)
        #expect(delta?.deltaTimeSeconds == 1.0)
        let cadence = CSCMeasurementParser.cadence(from: delta!)
        #expect(cadence.value == 0.0)
    }

    @Test func handlesWheelRevolutionWraparound() {
        var state = CSCMeasurementState(
            previousWheelRevolutions: UInt32.max - 1,
            previousWheelEventTime: 1_024,
        )

        let delta = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 1, eventTime: 2_048),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )

        #expect(delta?.deltaRevolutions == 3)
        let speed = CSCMeasurementParser.speed(from: delta!, circumferenceMeters: defaultCircumference)
        #expect(abs(speed.value - 6.315) < 0.001)
    }

    @Test func handlesCrankRevolutionWraparound() {
        var state = CSCMeasurementState(
            previousCrankRevolutions: UInt16.max,
            previousCrankEventTime: 1_024,
        )

        let delta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 0, eventTime: 2_048),
            previous: &state,
        )

        #expect(delta?.deltaRevolutions == 1)
        let cadence = CSCMeasurementParser.cadence(from: delta!)
        #expect(abs(cadence.value - 60.0) < 0.001)
    }

    @Test func wheelEventTimeWrapPlausible() {
        var state = CSCMeasurementState(
            previousWheelRevolutions: 100,
            previousWheelEventTime: 65_500,
        )

        let delta = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 101, eventTime: 100),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )

        #expect(delta?.deltaRevolutions == 1)
        let expectedDeltaTime = Double(UInt16(100) &- UInt16(65_500)) / 1024.0
        #expect(abs((delta?.deltaTimeSeconds ?? 0) - expectedDeltaTime) < 0.0001)
        let speed = CSCMeasurementParser.speed(from: delta!, circumferenceMeters: defaultCircumference)
        #expect(abs(speed.value - 15.85) < 0.1)
    }

    @Test func crankEventTimeWrapPlausible() {
        var state = CSCMeasurementState(
            previousCrankRevolutions: 10,
            previousCrankEventTime: 60_000,
        )

        let delta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 11, eventTime: 1_024),
            previous: &state,
        )

        #expect(delta?.deltaRevolutions == 1)
        let expectedDeltaTime = Double(UInt16(1_024) &- UInt16(60_000)) / 1024.0
        #expect(abs((delta?.deltaTimeSeconds ?? 0) - expectedDeltaTime) < 0.0001)
        let cadence = CSCMeasurementParser.cadence(from: delta!)
        #expect(abs(cadence.value - 9.366) < 0.1)
    }

    @Test func crankEventTimeWrapImplausibleRate() {
        var state = CSCMeasurementState(
            previousCrankRevolutions: 10,
            previousCrankEventTime: 65_500,
        )

        let delta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 11, eventTime: 100),
            previous: &state,
        )

        #expect(delta == nil)
        #expect(state.previousCrankRevolutions == 11)
        #expect(state.previousCrankEventTime == 100)
    }

    @Test func wheelImplausibleDeltaReseeds() {
        var state = CSCMeasurementState(
            previousWheelRevolutions: 10_000,
            previousWheelEventTime: 1_024,
        )

        let implausible = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 0, eventTime: 2_048),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )
        #expect(implausible == nil)
        #expect(state.previousWheelRevolutions == 0)

        let followUp = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 2, eventTime: 3_072),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )
        #expect(followUp?.deltaRevolutions == 2)
        let speed = CSCMeasurementParser.speed(from: followUp!, circumferenceMeters: defaultCircumference)
        #expect(abs(speed.value - 4.21) < 0.001)
    }

    @Test func crankImplausibleDeltaReseeds() {
        var state = CSCMeasurementState(
            previousCrankRevolutions: 5_000,
            previousCrankEventTime: 1_024,
        )

        let implausible = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 0, eventTime: 2_048),
            previous: &state,
        )
        #expect(implausible == nil)
        #expect(state.previousCrankRevolutions == 0)

        let followUp = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 1, eventTime: 3_072),
            previous: &state,
        )
        #expect(followUp?.deltaRevolutions == 1)
        let cadence = CSCMeasurementParser.cadence(from: followUp!)
        #expect(cadence.value == 60.0)
    }

    @Test func crankWrapVersusImplausible() {
        var state = CSCMeasurementState(
            previousCrankRevolutions: UInt16.max,
            previousCrankEventTime: 1_024,
        )

        let delta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 1, eventTime: 2_048),
            previous: &state,
        )

        #expect(delta?.deltaRevolutions == 2)
        let cadence = CSCMeasurementParser.cadence(from: delta!)
        #expect(cadence.value == 120.0)
    }

    @Test func crankNearBoundaryWrap() {
        var state = CSCMeasurementState(
            previousCrankRevolutions: UInt16.max - 1,
            previousCrankEventTime: 1_024,
        )

        let delta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 2, eventTime: 2_048),
            previous: &state,
        )

        #expect(delta?.deltaRevolutions == 4)
        let cadence = CSCMeasurementParser.cadence(from: delta!)
        #expect(cadence.value == 240.0)
    }

    @Test func wheelCapExactlyFiftyMetersPerSecondAccepted() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 0, eventTime: 0),
            previous: &state,
            circumferenceMeters: 1.0,
        )

        let delta = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 25, eventTime: 512),
            previous: &state,
            circumferenceMeters: 1.0,
        )

        #expect(delta != nil)
        let speed = CSCMeasurementParser.speed(from: delta!, circumferenceMeters: 1.0)
        #expect(speed.value == 50.0)
    }

    @Test func wheelCapJustOverFiftyRejected() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 0, eventTime: 0),
            previous: &state,
            circumferenceMeters: 1.0,
        )

        let rejected = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 25, eventTime: 511),
            previous: &state,
            circumferenceMeters: 1.0,
        )
        #expect(rejected == nil)

        let followUp = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 26, eventTime: 511 + 1_024),
            previous: &state,
            circumferenceMeters: 1.0,
        )
        #expect(followUp?.deltaRevolutions == 1)
        #expect(followUp?.deltaTimeSeconds == 1.0)
    }

    @Test func crankCapExactlyThreeHundredRPMAccepted() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 0, eventTime: 0),
            previous: &state,
        )

        let delta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 5, eventTime: 1_024),
            previous: &state,
        )

        #expect(delta != nil)
        let cadence = CSCMeasurementParser.cadence(from: delta!)
        #expect(cadence.value == 300.0)
    }

    @Test func crankCapJustOverThreeHundredRejected() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 0, eventTime: 0),
            previous: &state,
        )

        let rejected = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 5, eventTime: 1_023),
            previous: &state,
        )
        #expect(rejected == nil)

        let followUp = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 6, eventTime: 1_023 + 1_024),
            previous: &state,
        )
        #expect(followUp?.deltaRevolutions == 1)
        #expect(followUp?.deltaTimeSeconds == 1.0)
    }

    @Test func interleavedPacketsDoNotWipeWheelSeed() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 100, eventTime: 1_024),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )

        let absent = CSCMeasurementParser.wheelDelta(
            from: crankSample(revolutions: 10, eventTime: 1_024),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )
        #expect(absent == nil)
        #expect(state.previousWheelRevolutions == 100)
        #expect(state.previousWheelEventTime == 1_024)

        let delta = CSCMeasurementParser.wheelDelta(
            from: wheelSample(revolutions: 102, eventTime: 2_048),
            previous: &state,
            circumferenceMeters: defaultCircumference,
        )

        #expect(delta?.deltaRevolutions == 2)
    }

    @Test func interleavedPacketsDoNotWipeCrankSeed() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 10, eventTime: 1_024),
            previous: &state,
        )

        let absent = CSCMeasurementParser.crankDelta(
            from: wheelSample(revolutions: 100, eventTime: 1_024),
            previous: &state,
        )
        #expect(absent == nil)
        #expect(state.previousCrankRevolutions == 10)
        #expect(state.previousCrankEventTime == 1_024)

        let delta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 11, eventTime: 2_048),
            previous: &state,
        )

        #expect(delta?.deltaRevolutions == 1)
    }

    @Test func crankDeltaIgnoresCircumference() {
        var state = CSCMeasurementState()

        _ = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 10, eventTime: 1_024),
            previous: &state,
        )

        let delta = CSCMeasurementParser.crankDelta(
            from: crankSample(revolutions: 11, eventTime: 2_048),
            previous: &state,
        )

        #expect(delta?.deltaRevolutions == 1)
        #expect(delta?.deltaTimeSeconds == 1.0)
    }
}

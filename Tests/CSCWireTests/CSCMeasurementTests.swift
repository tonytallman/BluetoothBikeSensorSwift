import CSCWire
import Foundation
import Testing

@Suite struct CSCMeasurementTests {
    @Test func decodesWheelOnlyMeasurement() {
        let payload = CSCMeasurement(
            cumulativeWheelRevolutions: 1_000,
            lastWheelEventTime: 1_024,
        ).encode()!

        let sample = CSCMeasurement.decode(payload)
        #expect(sample?.cumulativeWheelRevolutions == 1_000)
        #expect(sample?.lastWheelEventTime == 1_024)
        #expect(sample?.cumulativeCrankRevolutions == nil)
    }

    @Test func decodesCrankOnlyMeasurement() {
        let payload = CSCMeasurement(
            cumulativeCrankRevolutions: 500,
            lastCrankEventTime: 2_048,
        ).encode()!

        let sample = CSCMeasurement.decode(payload)
        #expect(sample?.cumulativeCrankRevolutions == 500)
        #expect(sample?.lastCrankEventTime == 2_048)
        #expect(sample?.cumulativeWheelRevolutions == nil)
    }

    @Test func decodesCombinedMeasurement() {
        let payload = CSCMeasurement(
            cumulativeWheelRevolutions: 100,
            lastWheelEventTime: 1_024,
            cumulativeCrankRevolutions: 80,
            lastCrankEventTime: 2_048,
        ).encode()!

        let sample = CSCMeasurement.decode(payload)
        #expect(sample?.cumulativeWheelRevolutions == 100)
        #expect(sample?.lastWheelEventTime == 1_024)
        #expect(sample?.cumulativeCrankRevolutions == 80)
        #expect(sample?.lastCrankEventTime == 2_048)
    }

    @Test func rejectsShortPayload() {
        #expect(CSCMeasurement.decode(Data([0x03])) == nil)
    }

    @Test func rejectsEmptyPayload() {
        #expect(CSCMeasurement.decode(Data()) == nil)
    }

    @Test func incompleteWheelPairDoesNotEncode() {
        #expect(CSCMeasurement(cumulativeWheelRevolutions: 1).encode() == nil)
        #expect(CSCMeasurement(lastWheelEventTime: 1).encode() == nil)
    }

    @Test func incompleteCrankPairDoesNotEncode() {
        #expect(CSCMeasurement(cumulativeCrankRevolutions: 1).encode() == nil)
        #expect(CSCMeasurement(lastCrankEventTime: 1).encode() == nil)
    }

    @Test func roundTripsWheelMeasurement() {
        let original = CSCMeasurement(
            cumulativeWheelRevolutions: 1_000,
            lastWheelEventTime: 1_024,
        )
        let roundTripped = CSCMeasurement.decode(original.encode()!)
        #expect(roundTripped == original)
    }

    @Test func roundTripsCrankMeasurement() {
        let original = CSCMeasurement(
            cumulativeCrankRevolutions: 500,
            lastCrankEventTime: 2_048,
        )
        let roundTripped = CSCMeasurement.decode(original.encode()!)
        #expect(roundTripped == original)
    }

    @Test func roundTripsCombinedMeasurement() {
        let original = CSCMeasurement(
            cumulativeWheelRevolutions: 100,
            lastWheelEventTime: 1_024,
            cumulativeCrankRevolutions: 80,
            lastCrankEventTime: 2_048,
        )
        let roundTripped = CSCMeasurement.decode(original.encode()!)
        #expect(roundTripped == original)
    }

    @Test func trailingBytesIgnoredOnDecode() {
        var payload = CSCMeasurement(
            cumulativeWheelRevolutions: 100,
            lastWheelEventTime: 1_024,
        ).encode()!
        payload.append(contentsOf: [0xFF, 0xFF])

        let sample = CSCMeasurement.decode(payload)
        #expect(sample?.cumulativeWheelRevolutions == 100)
        #expect(sample?.lastWheelEventTime == 1_024)
    }

    @Test func mixedHalfSpecifiedPairsDoNotEncode() {
        #expect(
            CSCMeasurement(
                cumulativeWheelRevolutions: 10,
                cumulativeCrankRevolutions: 5,
                lastCrankEventTime: 100,
            ).encode() == nil,
        )
    }

    @Test func completeWheelPairWithHalfCrankPairDoesNotEncode() {
        #expect(
            CSCMeasurement(
                cumulativeWheelRevolutions: 10,
                lastWheelEventTime: 100,
                cumulativeCrankRevolutions: 5,
            ).encode() == nil,
        )
    }

    @Test func zeroFlagsDecodeReturnsNil() {
        #expect(CSCMeasurement.decode(Data([0x00])) == nil)
    }

    @Test func encodeIsCanonicalFlagsOnly() {
        let decoded = CSCMeasurement.decode(Data([0x81, 0x01, 0x00, 0x00, 0x00, 0x04, 0x00]))
        #expect(decoded?.cumulativeWheelRevolutions == 1)
        #expect(decoded?.lastWheelEventTime == 4)

        let encoded = decoded?.encode()
        #expect(encoded?.first == 0x01)
    }
}

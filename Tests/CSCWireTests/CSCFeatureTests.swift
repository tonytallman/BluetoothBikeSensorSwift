import CSCWire
import Foundation
import Testing

@Suite struct CSCFeatureTests {
    @Test func decodesWheelOnlyFeature() {
        let feature = CSCFeature.decode(Data([0x01, 0x00]))
        #expect(feature?.contains(.wheelRevolutionData) == true)
        #expect(feature?.contains(.crankRevolutionData) == false)
        #expect(feature?.contains(.multipleSensorLocations) == false)
    }

    @Test func decodesAllNamedFeatureBits() {
        let feature = CSCFeature.decode(Data([0x07, 0x00]))
        #expect(feature?.contains(.wheelRevolutionData) == true)
        #expect(feature?.contains(.crankRevolutionData) == true)
        #expect(feature?.contains(.multipleSensorLocations) == true)
    }

    @Test func rejectsZeroByteFeature() {
        #expect(CSCFeature.decode(Data()) == nil)
    }

    @Test func rejectsOneByteFeature() {
        #expect(CSCFeature.decode(Data([0x01])) == nil)
    }

    @Test func encodesMultipleSensorLocationsBit() {
        let encoded = CSCFeature([.multipleSensorLocations]).encode()
        #expect(encoded == Data([0x04, 0x00]))
    }

    @Test func encodesAllThreeNamedBits() {
        let encoded = CSCFeature([
            .wheelRevolutionData,
            .crankRevolutionData,
            .multipleSensorLocations,
        ]).encode()
        #expect(encoded == Data([0x07, 0x00]))
    }

    @Test func preservesHighBitsOnRoundTrip() {
        let payload = Data([0x07, 0x80])
        let feature = CSCFeature.decode(payload)
        #expect(feature?.encode() == payload)
    }

    @Test func trailingByteIgnoredOnDecode() {
        let feature = CSCFeature.decode(Data([0x01, 0x00, 0xFF]))
        #expect(feature?.contains(.wheelRevolutionData) == true)
        #expect(feature?.encode() == Data([0x01, 0x00]))
    }
}

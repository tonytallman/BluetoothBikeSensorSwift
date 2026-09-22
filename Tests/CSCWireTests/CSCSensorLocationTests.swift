import CSCWire
import Foundation
import Testing

@Suite struct CSCSensorLocationTests {
    @Test func decodesAssignedNumber() {
        let location = CSCSensorLocation.decode(Data([0x0A]))
        #expect(location?.assignedNumber == 10)
    }

    @Test func rejectsEmptyPayload() {
        #expect(CSCSensorLocation.decode(Data()) == nil)
    }

    @Test func roundTripsAssignedNumber() {
        let original = CSCSensorLocation(assignedNumber: 0x0A)
        let roundTripped = CSCSensorLocation.decode(original.encode())
        #expect(roundTripped == original)
    }

    @Test func decodesReservedAssignedNumber() {
        let location = CSCSensorLocation.decode(Data([0xFF]))
        #expect(location?.assignedNumber == 0xFF)
    }

    @Test func usesFirstByteWhenExtraBytesPresent() {
        let location = CSCSensorLocation.decode(Data([0x0A, 0x00]))
        #expect(location?.assignedNumber == 10)
    }
}

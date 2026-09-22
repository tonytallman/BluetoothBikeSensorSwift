import CSCClient
import CSCWire
import Foundation
import Testing

@Suite struct SensorLocationTests {
    @Test func mapsAssignedNumbersToKind() {
        let location = SensorLocation.fromAssignedNumber(0x0A)
        #expect(location.kind == .rearDropout)
        #expect(location.displayName == "Rear Dropout")
    }

    @Test func mapsReservedAssignedNumbers() {
        let location = SensorLocation.fromAssignedNumber(0xFF)
        #expect(location.kind == .reserved(0xFF))
        #expect(location.displayName == "Unknown (255)")
    }
}

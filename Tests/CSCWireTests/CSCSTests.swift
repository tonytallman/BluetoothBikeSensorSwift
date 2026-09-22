import CSCWire
import Foundation
import Testing

@Suite struct CSCSTests {
    @Test func standardUUIDsMatchBluetoothBase() {
        #expect(CSCS.serviceUUID == UUID(uuidString: "00001816-0000-1000-8000-00805F9B34FB"))
        #expect(CSCS.measurementUUID == UUID(uuidString: "00002A5B-0000-1000-8000-00805F9B34FB"))
        #expect(CSCS.featureUUID == UUID(uuidString: "00002A5C-0000-1000-8000-00805F9B34FB"))
        #expect(CSCS.sensorLocationUUID == UUID(uuidString: "00002A5D-0000-1000-8000-00805F9B34FB"))
        #expect(CSCS.controlPointUUID == UUID(uuidString: "00002A55-0000-1000-8000-00805F9B34FB"))
    }
}

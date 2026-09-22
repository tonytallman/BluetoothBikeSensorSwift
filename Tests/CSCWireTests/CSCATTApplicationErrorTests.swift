import CSCWire
import Testing

@Suite struct CSCATTApplicationErrorTests {
    @Test func rawValuesMatchSpec() {
        #expect(CSCATTApplicationError.procedureAlreadyInProgress.rawValue == 0x80)
        #expect(CSCATTApplicationError.cccdImproperlyConfigured.rawValue == 0x81)
    }

    @Test func initFromRawValue() {
        #expect(CSCATTApplicationError(rawValue: 0x80) == .procedureAlreadyInProgress)
        #expect(CSCATTApplicationError(rawValue: 0x81) == .cccdImproperlyConfigured)
        #expect(CSCATTApplicationError(rawValue: 0x00) == nil)
    }
}

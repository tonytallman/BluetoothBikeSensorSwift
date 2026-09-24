import CSCServer
import Testing
@testable import SampleServerApp

@Suite struct ServerConfigurationTests {
    @Test(arguments: [
        (RevolutionConfiguration.wheel, LocationConfiguration.none, UInt16(0x0001)),
        (RevolutionConfiguration.wheel, LocationConfiguration.fixed(.rearDropout), UInt16(0x0001)),
        (RevolutionConfiguration.wheel, LocationConfiguration.multiple(supported: [.frontWheel], current: .frontWheel), UInt16(0x0005)),
        (RevolutionConfiguration.crank, LocationConfiguration.none, UInt16(0x0002)),
        (RevolutionConfiguration.crank, LocationConfiguration.fixed(.rearDropout), UInt16(0x0002)),
        (RevolutionConfiguration.crank, LocationConfiguration.multiple(supported: [.leftCrank], current: .leftCrank), UInt16(0x0006)),
        (RevolutionConfiguration.wheelAndCrank, LocationConfiguration.none, UInt16(0x0003)),
        (RevolutionConfiguration.wheelAndCrank, LocationConfiguration.fixed(.rearDropout), UInt16(0x0003)),
        (RevolutionConfiguration.wheelAndCrank, LocationConfiguration.multiple(supported: [.frontWheel], current: .frontWheel), UInt16(0x0007)),
    ])
    func featureBits(
        revolutions: RevolutionConfiguration,
        location: LocationConfiguration,
        expected: UInt16,
    ) {
        let config = ServerConfiguration(revolutions: revolutions, location: location)
        #expect(config.expectedFeatureBits == expected)
    }

    @Test func crankNoneHasNoControlPoint() {
        let config = ServerConfiguration(revolutions: .crank, location: .none)
        #expect(!config.expectedCharacteristics.contains("Control Point"))
    }

    @Test func crankMultipleHasControlPoint() {
        let config = ServerConfiguration(
            revolutions: .crank,
            location: .multiple(supported: [.leftCrank], current: .leftCrank),
        )
        #expect(config.expectedCharacteristics.contains("Control Point"))
    }

    @Test func emptySupportedListValidation() {
        let config = ServerConfiguration(
            revolutions: .wheel,
            location: .multiple(supported: [], current: .frontWheel),
        )
        #expect(config.validationIssue == "Select at least one supported location.")
    }

    @Test func currentNotInSupportedValidation() {
        let config = ServerConfiguration(
            revolutions: .wheel,
            location: .multiple(supported: [.frontWheel], current: .rearDropout),
        )
        #expect(config.validationIssue != nil)
    }

    @Test func supportedLocationsInCatalogOrder() {
        let selection: Set<SensorLocationKind> = [.rearDropout, .frontWheel, .leftCrank]
        let ordered = SensorLocationCatalog.supportedKinds(from: selection)
        #expect(ordered == [.frontWheel, .leftCrank, .rearDropout])
    }
}

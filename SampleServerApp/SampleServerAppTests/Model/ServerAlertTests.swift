import CSCServer
import Testing
@testable import SampleServerApp

@Suite struct ServerAlertTests {
    @Test func cancellationReturnsNil() {
        #expect(
            ServerAlert.startFailure(
                CancellationError(),
                status: .poweredOn,
                authorization: .allowed,
            ) == nil,
        )
    }

    @Test func deniedAuthorizationOffersSettings() {
        let alert = ServerAlert.startFailure(
            ServerError.notPoweredOn,
            status: .poweredOff,
            authorization: .denied,
        )
        #expect(alert?.offersSettings == true)
    }

    @Test func unsupportedDeviceMessage() {
        let alert = ServerAlert.startFailure(
            ServerError.notPoweredOn,
            status: .unsupported,
            authorization: .allowed,
        )
        #expect(alert?.message.contains("Simulator") == true)
    }

    @Test func alreadyStartedMessage() {
        let alert = ServerAlert.startFailure(
            ServerError.alreadyStarted,
            status: .poweredOn,
            authorization: .allowed,
        )
        #expect(alert?.message.contains("Another server") == true)
    }

    @Test func publishFailedMessage() {
        let alert = ServerAlert.startFailure(
            ServerError.publishFailed(reason: "boom"),
            status: .poweredOn,
            authorization: .allowed,
        )
        #expect(alert?.message.contains("boom") == true)
    }

    @Test func advertisingFailedMessage() {
        let alert = ServerAlert.startFailure(
            ServerError.advertisingFailed(reason: "nope"),
            status: .poweredOn,
            authorization: .allowed,
        )
        #expect(alert?.message.contains("nope") == true)
    }

    @Test func unsupportedConfigurationMessage() {
        let alert = ServerAlert.startFailure(
            ServerError.unsupportedConfiguration,
            status: .poweredOn,
            authorization: .allowed,
        )
        #expect(alert?.message.contains("isn't supported") == true)
    }
}

package import CSCWire

/// CSC sensor server configuration built from revolution sequences and optional location settings.
public final class Server: Sendable {
    package let feature: CSCFeature
    package let service: PeripheralService
    package let wheel: WheelConfiguration?
    package let crankRevolutions: AnyAsyncSequence<CrankRevolution>?
    package let location: ServerLocationConfiguration

    internal init(
        feature: CSCFeature,
        service: PeripheralService,
        wheel: WheelConfiguration?,
        crankRevolutions: AnyAsyncSequence<CrankRevolution>?,
        location: ServerLocationConfiguration,
    ) {
        self.feature = feature
        self.service = service
        self.wheel = wheel
        self.crankRevolutions = crankRevolutions
        self.location = location
    }
}

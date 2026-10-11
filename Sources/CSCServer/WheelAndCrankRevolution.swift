/// One sample for ``Server/wheelAndCrankRevolutions(_:setCumulativeWheelRevolutions:)``,
/// sent as one CSC Measurement notification carrying both halves.
///
/// When only one of wheel or crank has a new event, repeat the other's latest count and event
/// time together, unchanged; an unchanged count and event time reads as no new event.
public struct WheelAndCrankRevolution: Sendable, Equatable {
    public let wheel: WheelRevolution
    public let crank: CrankRevolution

    public init(wheel: WheelRevolution, crank: CrankRevolution) {
        self.wheel = wheel
        self.crank = crank
    }
}

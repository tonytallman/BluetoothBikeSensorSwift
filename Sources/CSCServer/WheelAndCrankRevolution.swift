/// One element for ``Server/wheelAndCrankRevolutions(_:setCumulativeWheelRevolutions:)``.
/// The halves that are present are sent together in one CSC Measurement notification.
///
/// Include a half only when it has data to report. An element with neither half is dropped,
/// because a CSC Measurement must carry at least one of them.
public struct WheelAndCrankRevolution: Sendable, Equatable {
    public let wheel: WheelRevolution?
    public let crank: CrankRevolution?

    public init(wheel: WheelRevolution? = nil, crank: CrankRevolution? = nil) {
        self.wheel = wheel
        self.crank = crank
    }
}

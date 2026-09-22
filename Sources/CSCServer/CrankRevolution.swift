/// One crank revolution sample in CSC Measurement wire units (`UInt16` cumulative
/// revolutions and `UInt16` last-event time at 1/1024 s).
public struct CrankRevolution: Sendable, Equatable {
    public let cumulativeRevolutions: UInt16
    public let lastEventTime: UInt16

    public init(cumulativeRevolutions: UInt16, lastEventTime: UInt16) {
        self.cumulativeRevolutions = cumulativeRevolutions
        self.lastEventTime = lastEventTime
    }
}

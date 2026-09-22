/// One wheel revolution sample in CSC Measurement wire units (`UInt32` cumulative
/// revolutions and `UInt16` last-event time at 1/1024 s). The client type
/// ``WheelRevolutions`` is a different type.
public struct WheelRevolution: Sendable, Equatable {
    public let cumulativeRevolutions: UInt32
    public let lastEventTime: UInt16

    public init(cumulativeRevolutions: UInt32, lastEventTime: UInt16) {
        self.cumulativeRevolutions = cumulativeRevolutions
        self.lastEventTime = lastEventTime
    }
}

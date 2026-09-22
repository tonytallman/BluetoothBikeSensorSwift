/// Handles Set Cumulative Value (`0x01`) on SC Control Point for wheel revolution data.
public protocol SetCumulativeWheelRevolutions: Sendable {
    func setCumulativeWheelRevolutions(_ cumulativeRevolutions: UInt32) async throws
}

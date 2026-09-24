/// Handles Set Cumulative Value (`0x01`) on SC Control Point for wheel revolution data.
///
/// ``Server/stop()`` cancels an in-flight call and waits for it to return; honor task cancellation.
public protocol SetCumulativeWheelRevolutions: Sendable {
    func setCumulativeWheelRevolutions(_ cumulativeRevolutions: UInt32) async throws
}
